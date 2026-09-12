import Foundation
import Cocoa
import Cmpv
import Combine

public final class MPVPlayer: ObservableObject {
    public static let shared = MPVPlayer()
    
    // MARK: - Published State
    @Published public var playbackState: PlaybackState = .idle
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var volume: Double = 80
    @Published public var isMuted: Bool = false
    @Published public var mediaTitle: String = ""
    @Published public var currentFileURL: URL? = nil
    
    @Published public var audioTracks: [MediaTrack] = []
    @Published public var subtitleTracks: [MediaTrack] = []
    @Published public var currentAudioTrackId: Int? = nil
    @Published public var currentPrimarySubId: Int? = nil
    @Published public var currentSecondarySubId: Int? = nil
    
    @Published public var currentSubText: String = ""
    @Published public var currentSecondarySubText: String = ""
    @Published public var isPeekingRussian: Bool = false
    @Published public var showSubtitles: Bool = true
    
    @Published public var subFontSize: Double = 46 {
        didSet {
            UserDefaults.standard.set(subFontSize, forKey: "VPlayer.subFontSize")
            applySubtitleStyle()
        }
    }
    
    @Published public var subtitleHistory: [String] = []
    
    // MARK: - Internal mpv handle
    private var mpv: OpaquePointer?
    private var eventThread: Thread?
    private var isRunning: Bool = false
    private var targetView: NSView?
    private var embedTimer: Timer?
    private var mpvChildWindow: NSWindow?
    private var isExitingFullscreen = false
    /// Last value of mpv's `pause` property, needed to pick the right state
    /// when playback leaves EOF (a seek back while paused must stay paused).
    private var isMpvPaused = false
    /// True between issuing a seek and mpv's PLAYBACK_RESTART. While set,
    /// stale `time-pos` updates are dropped so the timeline does not jump back
    /// to the old position before the seek completes.
    private var isSeekInFlight = false
    private var seekSettleWorkItem: DispatchWorkItem?

    /// AppKit rounds normal windows, while mpv renders into a separate child window.
    /// Keep the two surfaces visually identical outside fullscreen. Used only when
    /// the actual radius cannot be read from the parent window (pre-Tahoe value).
    private let fallbackEmbeddedWindowCornerRadius: CGFloat = 10
    private let fullscreenVideoWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.normal.rawValue - 1
    )
    
    public init() {
        if let savedSize = UserDefaults.standard.value(forKey: "VPlayer.subFontSize") as? Double, savedSize > 15 {
            self.subFontSize = savedSize
        }
    }
    
    deinit {
        destroyMPV()
    }
    
    // MARK: - Setup & Binding
    public func attach(view: NSView) {
        guard view.window != nil else {
            return
        }
        self.targetView = view
        if self.mpv == nil {
            setupMPV()
        } else {
            attachMpvChildWindowIfNeeded()
        }
        
        if let pending = self.currentFileURL {
            self.loadFile(url: pending)
        }
    }
    
    private func setupMPV() {
        guard self.mpv == nil, let view = targetView, view.window != nil else { return }
        
        guard let handle = mpv_create() else {
            return
        }
        self.mpv = handle
        
        // 1. Embedded options to prevent hook hanging and detached separate window
        mpv_set_option_string(handle, "hwdec", "auto")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "input-media-keys", "no")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-cursor", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "macos-app-activation-policy", "regular")
        mpv_set_option_string(handle, "macos-geometry-calculation", "whole")
        // mpv owns a separate NSWindow here. It must not resize that window to
        // the video's aspect ratio, because AppKit owns its geometry instead.
        mpv_set_option_string(handle, "auto-window-resize", "no")
        mpv_set_option_string(handle, "keepaspect-window", "no")
        
        mpv_set_option_string(handle, "border", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "osd-bar", "no")
        
        // Hide mpv's internal subtitles text so our SwiftUI layer doesn't collide
        mpv_set_option_string(handle, "sub-color", "1.0/1.0/1.0/0.0")
        mpv_set_option_string(handle, "sub-border-color", "0.0/0.0/0.0/0.0")
        mpv_set_option_string(handle, "sub-shadow-color", "0.0/0.0/0.0/0.0")
        
        // 2. High quality video & audio defaults
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "sub-auto", "fuzzy")
        mpv_set_option_string(handle, "secondary-sub-visibility", "no")
        
        // 3. Initialize
        let initStatus = mpv_initialize(handle)
        if initStatus < 0 {
            return
        }
        
        // 4. Apply subtitle styling defaults
        applySubtitleStyle()
        
        // 5. Observe properties
        observeProperties(handle)
        
        // 6. Start event loop thread
        isRunning = true
        eventThread = Thread { [weak self] in
            self?.runEventLoop()
        }
        eventThread?.name = "VPlayer.MPVEventThread"
        eventThread?.start()
    }
    
    private func destroyMPV() {
        embedTimer?.invalidate()
        embedTimer = nil
        if let child = mpvChildWindow {
            targetView?.window?.removeChildWindow(child)
            child.orderOut(nil)
            self.mpvChildWindow = nil
        }
        isRunning = false
        if let handle = mpv {
            self.mpv = nil
            mpv_terminate_destroy(handle)
        }
        eventThread?.cancel()
        eventThread = nil
    }
    
    private func observeProperties(_ handle: OpaquePointer) {
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 5, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 6, "sub-text", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 7, "secondary-sub-text", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 9, "media-title", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 10, "current-tracks/audio/id", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 11, "current-tracks/sub/id", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 12, "current-tracks/sub2/id", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 13, "eof-reached", MPV_FORMAT_FLAG)
    }
    
    // MARK: - Asynchronous Command Helper (Deadlock-free!)
    private func executeCommand(_ args: [String]) {
        guard let handle = mpv else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        _ = mpv_command_async(handle, 0, &cArgs)
        for ptr in cArgs where ptr != nil {
            free(UnsafeMutableRawPointer(mutating: ptr))
        }
    }
    
    private func setPropertyAsync(_ name: String, _ val: String) {
        executeCommand(["set", name, val])
    }
    
    // MARK: - Subtitle Styling
    public func applySubtitleStyle() {
        let sizeStr = "\(Int(subFontSize))"
        setPropertyAsync("sub-font-size", sizeStr)
        setPropertyAsync("sub-border-size", "0")
        setPropertyAsync("sub-border-color", "0.0/0.0/0.0/0.0")
        setPropertyAsync("sub-color", "1.0/1.0/1.0/0.0")
        setPropertyAsync("sub-shadow-color", "0.0/0.0/0.0/0.0")
    }
    
    // MARK: - Native Child Window Attachment
    public func attachMpvChildWindowIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let target = self.targetView, let parentWindow = target.window else { return }
            
            if self.mpvChildWindow != nil {
                self.updateChildWindowFrame()
                return
            }
            
            for window in NSApp.windows {
                guard window !== parentWindow else { continue }
                let typeName = String(describing: type(of: window))
                let hasMpvView = window.contentView?.subviews.contains(where: {
                    let subType = String(describing: type(of: $0))
                    return subType == "View" || subType.contains("TitleBar")
                }) ?? false
                
                if typeName == "Window" || hasMpvView {
                    parentWindow.collectionBehavior = [.fullScreenPrimary]
                    window.styleMask = [.borderless]
                    window.hasShadow = false
                    window.ignoresMouseEvents = true
                    window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

                    self.configureEmbeddedWindow(window, in: parentWindow)
                    window.setFrame(self.embeddedWindowFrame(for: parentWindow), display: true)
                    self.updateEmbeddedWindowOrdering(window, in: parentWindow)
                    self.mpvChildWindow = window
                    self.embedTimer?.invalidate()
                    self.embedTimer = nil
                    break
                }
            }
        }
    }
    
    public func updateChildWindowFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let target = self.targetView,
                  let parent = target.window,
                  let child = self.mpvChildWindow else { return }

            // Do not reorder or resize either window while AppKit is restoring
            // the pre-fullscreen frame. didExitFullScreen performs the final sync.
            guard !self.isExitingFullscreen else { return }
            
            // Ensure child is borderless, participates in fullscreen space, and doesn't intercept clicks.
            if child.styleMask != [.borderless] {
                child.styleMask = [.borderless]
            }
            if !child.collectionBehavior.contains(.fullScreenAuxiliary) {
                child.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            }
            child.ignoresMouseEvents = true
            child.hasShadow = false
            
            self.configureEmbeddedWindow(child, in: parent)
            let targetFrame = self.embeddedWindowFrame(for: parent)

            // A child NSWindow is constrained to the parent's content layout rect
            // in native fullscreen, which is 30 pt below the top of this display.
            // Detach it there and keep it directly below the transparent overlay.
            self.updateEmbeddedWindowOrdering(child, in: parent)

            if child.frame != targetFrame {
                child.setFrame(targetFrame, display: true)
            }

            if parent.styleMask.contains(.fullScreen) {
                // mpv's window can adjust a full frame back to visibleFrame. A
                // direct origin update after resizing avoids that 30 pt shift.
                child.setFrameOrigin(targetFrame.origin)
                child.order(.below, relativeTo: parent.windowNumber)
            }
        }
    }

    public func prepareForFullscreenExit() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let parent = self.targetView?.window,
                  let child = self.mpvChildWindow else { return }

            self.isExitingFullscreen = true
            NSApp.presentationOptions = []

            // Restore the child relationship before AppKit animates the parent
            // back to its saved windowed frame.
            if !(parent.childWindows?.contains(child) ?? false) {
                parent.addChildWindow(child, ordered: .below)
            }
        }
    }

    public func finishFullscreenTransition() {
        DispatchQueue.main.async { [weak self] in
            self?.isExitingFullscreen = false
            self?.updateChildWindowFrame()
        }
    }

    /// During the native fullscreen animation the parent frame can briefly retain
    /// a title-bar-sized inset. The physical screen frame never has that inset.
    private func embeddedWindowFrame(for parent: NSWindow) -> NSRect {
        if parent.styleMask.contains(.fullScreen), let screenFrame = parent.screen?.frame {
            return screenFrame
        }

        guard let target = targetView else { return parent.frame }
        let rectInWindow = target.convert(target.bounds, to: nil)
        let screenRect = parent.convertToScreen(rectInWindow)
        return screenRect.width > 0 && screenRect.height > 0 ? screenRect : parent.frame
    }

    private func configureEmbeddedWindow(_ child: NSWindow, in parent: NSWindow) {
        child.isOpaque = false
        child.backgroundColor = .clear

        guard let contentView = child.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.layer?.cornerRadius = parent.styleMask.contains(.fullScreen) ? 0 : windowCornerRadius(of: parent)
    }

    /// The radius AppKit applies to the parent window's corners. It differs
    /// between macOS releases (10 pt before Tahoe, 16 pt on Tahoe), so a
    /// hardcoded value lets the video surface poke out at the corners.
    private func windowCornerRadius(of window: NSWindow) -> CGFloat {
        let key = "cornerRadius"
        if let themeFrame = window.contentView?.superview,
           themeFrame.responds(to: NSSelectorFromString(key)),
           let radius = themeFrame.value(forKey: key) as? CGFloat,
           radius > 0 {
            return radius
        }
        return fallbackEmbeddedWindowCornerRadius
    }

    private func updateEmbeddedWindowOrdering(_ child: NSWindow, in parent: NSWindow) {
        let isAttached = parent.childWindows?.contains(child) ?? false

        if parent.styleMask.contains(.fullScreen) {
            // autoHide (not hide): the menu bar and Dock stay out of the way but
            // slide in when the cursor reaches the screen edge, like any native
            // fullscreen app. `.hideMenuBar` would suppress that reveal entirely.
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            // mpv may bring its own window forward after rendering starts. Keep
            // it on a stable lower level so the transparent SwiftUI window with
            // subtitles and controls always stays above it.
            child.level = fullscreenVideoWindowLevel
            parent.level = .normal
            if isAttached {
                parent.removeChildWindow(child)
            }
            child.order(.below, relativeTo: parent.windowNumber)
        } else {
            NSApp.presentationOptions = []
            child.level = .normal
            parent.level = .normal
            if !isAttached {
                parent.addChildWindow(child, ordered: .below)
            }
        }
    }
    
    public func toggleFullscreen() {
        DispatchQueue.main.async { [weak self] in
            guard let win = self?.targetView?.window else { return }
            win.toggleFullScreen(nil)
        }
    }
    
    public var isFullscreen: Bool {
        return targetView?.window?.styleMask.contains(.fullScreen) ?? false
    }
    
    public func startEmbeddingPolling() {
        embedTimer?.invalidate()
        var attempts = 0
        embedTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            attempts += 1
            self?.attachMpvChildWindowIfNeeded()
            if attempts > 60 { // 3 seconds timeout
                timer.invalidate()
            }
        }
    }
    
    // MARK: - Playback Controls
    public func loadFile(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.playbackState = .idle
            return
        }
        self.currentFileURL = url
        self.mediaTitle = url.deletingPathExtension().lastPathComponent
        self.playbackState = .loading
        self.subtitleHistory.removeAll()
        
        guard mpv != nil, targetView?.window != nil else {
            return
        }
        
        startEmbeddingPolling()
        
        setPropertyAsync("pause", "no")
        executeCommand(["loadfile", url.path, "replace"])
    }
    
    public func togglePlayPause() {
        if playbackState == .finished {
            restartFromBeginning()
            return
        }
        executeCommand(["cycle", "pause"])
    }
    
    public func play() {
        if playbackState == .finished {
            restartFromBeginning()
            return
        }
        setPropertyAsync("pause", "no")
    }

    /// With `keep-open=yes` mpv holds the last frame at EOF, so unpausing
    /// there would just flip the icon. Behave like every other player: start over.
    private func restartFromBeginning() {
        beginSeek(optimisticTime: 0)
        executeCommand(["seek", "0", "absolute"])
        setPropertyAsync("pause", "no")
    }
    
    public func pause() {
        setPropertyAsync("pause", "yes")
    }
    
    public func seek(to seconds: Double) {
        let sec = max(0, min(seconds, duration))
        beginSeek(optimisticTime: sec)
        executeCommand(["seek", "\(sec)", "absolute+exact"])
    }
    
    public func seekRelative(seconds: Double) {
        beginSeek(optimisticTime: max(0, min(currentTime + seconds, duration)))
        executeCommand(["seek", "\(seconds)", "relative"])
    }
    
    public func seekSubtitle(direction: Int) {
        beginSeek(optimisticTime: nil)
        executeCommand(["sub-seek", "\(direction)"])
    }

    private func beginSeek(optimisticTime: Double?) {
        // Must apply synchronously when called from the UI: the caller's next
        // state change (e.g. dropping the scrub value) renders in the same
        // frame, and an async update would let a stale currentTime flash first.
        let apply = { [weak self] in
            guard let self else { return }
            self.isSeekInFlight = true
            if let optimisticTime {
                self.currentTime = optimisticTime
            }
            // Safety net: a seek to the current position may not emit
            // PLAYBACK_RESTART, so never stay deaf to time-pos for long.
            self.seekSettleWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.isSeekInFlight = false }
            self.seekSettleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func endSeek() {
        seekSettleWorkItem?.cancel()
        seekSettleWorkItem = nil
        isSeekInFlight = false
    }
    
    public func setVolume(_ val: Double) {
        let vol = max(0, min(val, 100))
        setPropertyAsync("volume", "\(vol)")
    }
    
    public func toggleMute() {
        executeCommand(["cycle", "mute"])
    }
    
    // MARK: - Language Learning & Subtitle Methods
    public func setPeekingRussian(_ isPeeking: Bool) {
        self.isPeekingRussian = isPeeking
        let val = isPeeking ? "yes" : "no"
        setPropertyAsync("secondary-sub-visibility", val)
    }
    
    public func setPrimarySubtitle(trackId: Int?) {
        let val = trackId != nil ? "\(trackId!)" : "no"
        setPropertyAsync("sid", val)
        self.currentPrimarySubId = trackId
    }
    
    public func setSecondarySubtitle(trackId: Int?) {
        let val = trackId != nil ? "\(trackId!)" : "no"
        setPropertyAsync("secondary-sid", val)
        self.currentSecondarySubId = trackId
    }
    
    public func setAudioTrack(trackId: Int?) {
        let val = trackId != nil ? "\(trackId!)" : "no"
        setPropertyAsync("aid", val)
        self.currentAudioTrackId = trackId
    }
    
    public func loadExternalSubtitle(fileURL: URL) {
        _ = fileURL.startAccessingSecurityScopedResource()
        executeCommand(["sub-add", fileURL.path, "cached", fileURL.lastPathComponent])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshTrackList()
        }
    }
    
    // MARK: - Background Event Loop
    private func runEventLoop() {
        while isRunning {
            guard let handle = self.mpv else { break }
            let event = mpv_wait_event(handle, 0.05)
            guard let ev = event else { continue }
            
            switch ev.pointee.event_id {
            case MPV_EVENT_NONE:
                break
                
            case MPV_EVENT_VIDEO_RECONFIG:
                attachMpvChildWindowIfNeeded()
                
            case MPV_EVENT_FILE_LOADED, MPV_EVENT_PLAYBACK_RESTART:
                attachMpvChildWindowIfNeeded()
                // PLAYBACK_RESTART also fires after every seek, so honour the
                // actual pause flag instead of assuming playback resumed.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.endSeek()
                    guard self.playbackState != .finished else { return }
                    self.playbackState = self.isMpvPaused ? .paused : .playing
                }
                // Delay track queries slightly to allow video reconfig without any mutex contention
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.refreshTrackList()
                    self?.autoSelectDualSubtitles()
                }
                
            case MPV_EVENT_END_FILE:
                DispatchQueue.main.async { [weak self] in
                    self?.playbackState = .finished
                }
                
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(ev.pointee.data)
                
            case MPV_EVENT_SHUTDOWN:
                isRunning = false
                break
                
            default:
                break
            }
        }
    }
    
    private func handlePropertyChange(_ dataPtr: UnsafeMutableRawPointer?) {
        guard let dataPtr = dataPtr else { return }
        let prop = dataPtr.assumingMemoryBound(to: mpv_event_property.self).pointee
        let propName = String(cString: prop.name)
        
        switch propName {
        case "time-pos":
            if let data = prop.data {
                let time = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isSeekInFlight else { return }
                    self.currentTime = time
                    if self.playbackState == .loading {
                        self.playbackState = .playing
                    }
                }
            }
            
        case "duration":
            if let data = prop.data {
                let dur = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    self?.duration = dur
                }
            }
            
        case "pause":
            if let data = prop.data {
                let isPaused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isMpvPaused = isPaused
                    if self.playbackState != .idle && self.playbackState != .finished {
                        self.playbackState = isPaused ? .paused : .playing
                    }
                }
            }

        case "eof-reached":
            // keep-open=yes means END_FILE never fires at the end of a file;
            // this property is the reliable signal that playback has finished.
            if let data = prop.data {
                let atEOF = data.assumingMemoryBound(to: Int32.self).pointee != 0
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.playbackState != .idle else { return }
                    if atEOF {
                        self.playbackState = .finished
                    } else if self.playbackState == .finished {
                        self.playbackState = self.isMpvPaused ? .paused : .playing
                    }
                }
            }
            
        case "volume":
            if let data = prop.data {
                let vol = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    self?.volume = vol
                }
            }
            
        case "mute":
            if let data = prop.data {
                let muted = data.assumingMemoryBound(to: Int32.self).pointee != 0
                DispatchQueue.main.async { [weak self] in
                    self?.isMuted = muted
                }
            }
            
        case "media-title":
            if let data = prop.data {
                let cStr = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
                let title = String(cString: cStr)
                DispatchQueue.main.async { [weak self] in
                    self?.mediaTitle = title
                }
            }

        case "current-tracks/audio/id":
            if let data = prop.data {
                let trackID = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                DispatchQueue.main.async { [weak self] in
                    self?.currentAudioTrackId = trackID > 0 ? trackID : nil
                }
            }

        case "current-tracks/sub/id":
            if let data = prop.data {
                let trackID = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                DispatchQueue.main.async { [weak self] in
                    self?.currentPrimarySubId = trackID > 0 ? trackID : nil
                }
            }

        case "current-tracks/sub2/id":
            if let data = prop.data {
                let trackID = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                DispatchQueue.main.async { [weak self] in
                    self?.currentSecondarySubId = trackID > 0 ? trackID : nil
                }
            }
            
        case "sub-text":
            var text = ""
            if let data = prop.data {
                let cStr = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
                text = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentSubText = text
                if !text.isEmpty && self.subtitleHistory.last != text {
                    self.subtitleHistory.append(text)
                    if self.subtitleHistory.count > 10 {
                        self.subtitleHistory.removeFirst()
                    }
                }
            }
            
        case "secondary-sub-text":
            var text = ""
            if let data = prop.data {
                let cStr = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
                text = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async { [weak self] in
                self?.currentSecondarySubText = text
            }
            
        default:
            break
        }
    }
    
    // MARK: - Track Management
    public func refreshTrackList() {
        guard let handle = mpv else { return }
        
        var count: Int64 = 0
        mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count)
        
        var newAudios: [MediaTrack] = []
        var newSubs: [MediaTrack] = []
        let selectedAudioID = currentTrackID(handle, property: "current-tracks/audio/id")
        let selectedPrimarySubID = currentTrackID(handle, property: "current-tracks/sub/id")
        let selectedSecondarySubID = currentTrackID(handle, property: "current-tracks/sub2/id")
        
        for i in 0..<count {
            guard let typeStr = getTrackProp(handle, idx: i, prop: "type") else { continue }
            let idVal: Int64 = getTrackInt(handle, idx: i, prop: "id") ?? Int64(i + 1)
            let title = getTrackProp(handle, idx: i, prop: "title") ?? ""
            let lang = getTrackProp(handle, idx: i, prop: "lang")
            let isSel = getTrackFlag(handle, idx: i, prop: "selected")
            let isDef = getTrackFlag(handle, idx: i, prop: "default")
            let isExt = getTrackFlag(handle, idx: i, prop: "external")
            
            if typeStr == "audio" {
                let isCurrent = selectedAudioID == Int(idVal) || isSel
                newAudios.append(MediaTrack(id: Int(idVal),
                                            type: .audio,
                                            title: title,
                                            lang: lang,
                                            isDefault: isDef,
                                            isSelected: isCurrent,
                                            isExternal: isExt))
            } else if typeStr == "sub" {
                let isCurrent = selectedPrimarySubID == Int(idVal) || selectedSecondarySubID == Int(idVal) || isSel
                newSubs.append(MediaTrack(id: Int(idVal),
                                          type: .sub,
                                          title: title,
                                          lang: lang,
                                          isDefault: isDef,
                                          isSelected: isCurrent,
                                          isExternal: isExt))
            }
        }
        
        self.audioTracks = newAudios
        self.subtitleTracks = newSubs
        self.currentAudioTrackId = selectedAudioID ?? newAudios.first(where: \.isSelected)?.id
        self.currentPrimarySubId = selectedPrimarySubID
        self.currentSecondarySubId = selectedSecondarySubID
    }
    
    public func autoSelectDualSubtitles() {
        let enSub = subtitleTracks.first { track in
            let l = track.lang?.lowercased() ?? ""
            let t = track.title.lowercased()
            return l.contains("en") || t.contains("english") || t.contains("англ")
        } ?? subtitleTracks.first
        
        let ruSub = subtitleTracks.first { track in
            let l = track.lang?.lowercased() ?? ""
            let t = track.title.lowercased()
            return (l.contains("ru") || t.contains("russian") || t.contains("рус")) && track.id != enSub?.id
        }
        
        if let en = enSub {
            setPrimarySubtitle(trackId: en.id)
        }
        if let ru = ruSub {
            setSecondarySubtitle(trackId: ru.id)
            setPropertyAsync("secondary-sub-visibility", "no")
        }
    }
    
    private func getTrackProp(_ handle: OpaquePointer, idx: Int64, prop: String) -> String? {
        let key = "track-list/\(idx)/\(prop)"
        guard let cStr = mpv_get_property_string(handle, key) else { return nil }
        defer { mpv_free(cStr) }
        return String(cString: cStr)
    }
    
    private func getTrackInt(_ handle: OpaquePointer, idx: Int64, prop: String) -> Int64? {
        let key = "track-list/\(idx)/\(prop)"
        var val: Int64 = 0
        let status = mpv_get_property(handle, key, MPV_FORMAT_INT64, &val)
        return status >= 0 ? val : nil
    }

    private func getTrackFlag(_ handle: OpaquePointer, idx: Int64, prop: String) -> Bool {
        let key = "track-list/\(idx)/\(prop)"
        var value: Int32 = 0
        let status = mpv_get_property(handle, key, MPV_FORMAT_FLAG, &value)
        return status >= 0 && value != 0
    }

    private func currentTrackID(_ handle: OpaquePointer, property: String) -> Int? {
        var value: Int64 = 0
        let status = mpv_get_property(handle, property, MPV_FORMAT_INT64, &value)
        return status >= 0 && value > 0 ? Int(value) : nil
    }
}
