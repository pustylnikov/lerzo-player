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
    /// Remembered between sessions; mute is not (a remembered mute reads as
    /// "no sound, why?" on the next launch).
    @Published public var volume: Double = 80 {
        didSet { UserDefaults.standard.set(volume, forKey: Self.volumeKey) }
    }
    private static let volumeKey = "LerzoPlayer.volume"
    @Published public var isMuted: Bool = false
    /// Playback speed multiplier. Not persisted: slowing down is tied to a
    /// hard passage, not a preference, so every file starts at 1x.
    @Published public var playbackSpeed: Double = 1.0
    public static let speedRange = 0.5...3.0
    public static let speedStep = 0.1
    public static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    /// A/V and subtitle offsets in seconds; positive delays that stream. They
    /// belong to one badly muxed file, so they reset when another file loads.
    @Published public private(set) var subDelay: Double = 0
    @Published public private(set) var secondarySubDelay: Double = 0
    @Published public private(set) var audioDelay: Double = 0
    public static let delayRange = -30.0...30.0
    public static let delayStep = 0.1
    /// Picture geometry, all per file like the delays. `videoZoom` is mpv's
    /// log2 scale (0 = 100 %, 1 = 200 %); pan is a fraction of the scaled
    /// video, so the point under the window centre stays put while zooming.
    @Published public private(set) var videoZoom: Double = 0
    @Published public private(set) var videoPanX: Double = 0
    @Published public private(set) var videoPanY: Double = 0
    /// True in "fill" mode (mpv panscan=1): the video covers the whole
    /// window and the overflowing edges are cut off.
    @Published public private(set) var fillsWindow: Bool = false
    /// mpv `video-crop` string ("WxH+X+Y"), empty when nothing is cropped.
    @Published public private(set) var videoCrop: String = ""
    public static let zoomRange = 0.5...4.0         // as a scale: 50 % … 400 %
    /// One key press changes the scale by this many percentage points.
    public static let zoomStep = 0.02
    public static let zoomPresets: [Double] = [1.0, 1.25, 1.5, 2.0]
    public static let panStep = 0.02
    @Published public var mediaTitle: String = ""
    @Published public var currentFileURL: URL? = nil
    
    @Published public var audioTracks: [MediaTrack] = []
    @Published public var subtitleTracks: [MediaTrack] = []
    @Published public var currentAudioTrackId: Int? = nil
    @Published public var currentPrimarySubId: Int? = nil {
        didSet { if currentPrimarySubId != oldValue { updateSubtitleTimeline() } }
    }
    @Published public var currentSecondarySubId: Int? = nil

    /// Every cue of the primary subtitle track, for exact line-by-line seeks.
    /// `nil` while loading, for bitmap subtitles, or without a track.
    private var subtitleTimeline: SubtitleTimeline?
    /// "<file>#<ff-index>" of the track `subtitleTimeline` is for or being loaded for.
    private var subtitleTimelineKey: String?
    private var subtitleTimelineCache: [String: SubtitleTimeline] = [:]
    private var subtitleTimelinesLoading: Set<String> = []
    
    @Published public var currentSubText: String = ""
    @Published public var currentSecondarySubText: String = ""
    /// True while TAB is held. Only meaningful in the `.peek` translation mode,
    /// but tracked in both so the "nothing to show" hint can react to TAB.
    @Published public var isPeekingTranslation: Bool = false

    /// How the second (translation) subtitle track is shown: only while TAB is
    /// held, or permanently as dual subtitles.
    public enum TranslationMode: String, CaseIterable, Identifiable {
        case peek, always
        public var id: String { rawValue }
    }
    @Published public var translationMode: TranslationMode = .peek {
        didSet { UserDefaults.standard.set(translationMode.rawValue, forKey: "LerzoPlayer.translationMode") }
    }
    /// Whether the translation line is on screen right now (given it has text).
    public var isTranslationShown: Bool {
        translationMode == .always || isPeekingTranslation
    }
    public func toggleTranslationMode() {
        translationMode = translationMode == .peek ? .always : .peek
    }

    /// Why the translation cannot be shown for the loaded file, if it cannot.
    public enum TranslationUnavailableReason: Equatable {
        /// The file has no subtitle tracks at all.
        case noSubtitleTracks
        /// The only subtitle track is already the primary one.
        case singleTrack
        /// There are tracks to choose from, but no second track is selected.
        case noSecondaryTrack
    }
    public var translationUnavailableReason: TranslationUnavailableReason? {
        guard currentFileURL != nil else { return nil }
        if subtitleTracks.isEmpty { return .noSubtitleTracks }
        guard currentSecondarySubId == nil else { return nil }
        return subtitleTracks.count == 1 ? .singleTrack : .noSecondaryTrack
    }
    
    /// Rendered point size of the primary subtitle words.
    @Published public var subFontSize: Double = MPVPlayer.defaultSubFontSize {
        didSet {
            UserDefaults.standard.set(subFontSize, forKey: MPVPlayer.subFontSizeKey)
            applySubtitleStyle()
        }
    }
    public static let defaultSubFontSize = 30.0
    public static let subFontSizeRange = 16.0...60.0
    private static let subFontSizeKey = "LerzoPlayer.subFontSizePt"
    /// Pre-1.x key that stored a nominal mpv size; the words were drawn at 65 % of it.
    private static let legacySubFontSizeKey = "LerzoPlayer.subFontSize"
    
    @Published public var subtitleHistory: [String] = []

    /// Pause at the end of every subtitle line; Space carries on to the
    /// next one. A study-session mode: it survives opening another file but
    /// not relaunching, so the player always starts in plain watching mode.
    @Published public var autoPauseAfterLine: Bool = false
    /// How long after a line's end auto-pause waits before pausing, for
    /// subtitles whose cues end on the last syllable. Per session and per
    /// file (reset on load), like the delays: it compensates for the file.
    @Published public private(set) var autoPauseTail: Double = 0
    public static let autoPauseTailStep = 0.1
    public static let autoPauseTailRange = 0.0...3.0
    /// A line has ended and its pause is due at `at` (video clock).
    private var pendingAutoPause: (cueIndex: Int, at: Double)?
    /// The line auto-pause last stopped at, so resuming does not stop there again.
    private var autoPausedCueIndex: Int?
    /// The line under playback at the previous `time-pos` tick; a change
    /// means that line has ended. `nil` after a seek and while auto-pause is off.
    private var lineUnderPlayback: Int?
    /// Last translation text seen while `lineUnderPlayback` was on screen, so
    /// the held line can keep its translation too.
    private var translationSeen: (cueIndex: Int, text: String)?
    /// True while the current pause was made by auto-pause rather than the
    /// user: W/E then mean "go on", while a manual pause is left alone.
    private var isAutoPaused = false {
        didSet { if !isAutoPaused { heldLine = nil } }
    }
    /// The line auto-pause stopped at. Playback stands on the first frame
    /// past its end, where mpv has already cleared `sub-text`, so the layer
    /// draws this instead of a blank until playback moves on.
    @Published public private(set) var heldLine: (text: String, translation: String)?
    /// What the subtitle layer should draw: mpv's current text, or the
    /// held line while auto-paused just past its end.
    public var subTextOnScreen: String {
        currentSubText.isEmpty ? heldLine?.text ?? "" : currentSubText
    }
    public var secondarySubTextOnScreen: String {
        currentSecondarySubText.isEmpty ? heldLine?.translation ?? "" : currentSecondarySubText
    }

    /// What mpv's A–B loop is currently doing for us.
    public enum LoopMode: Equatable {
        case off
        /// Repeating one line of the primary subtitle track (index into its timeline).
        case line(cueIndex: Int)
        /// Manual A–B loop; `b == nil` while only the start has been set.
        case ab(a: Double, b: Double?)
    }
    @Published public private(set) var loopMode: LoopMode = .off
    public var isLoopingLine: Bool {
        if case .line = loopMode { return true }
        return false
    }
    /// Hold-to-peek pauses playback so the translation can actually be read
    /// before the next line or scene arrives; playback resumes on release.
    @Published public var pauseWhilePeeking: Bool = true {
        didSet { UserDefaults.standard.set(pauseWhilePeeking, forKey: "LerzoPlayer.pauseWhilePeeking") }
    }
    private var didPauseForPeek = false
    /// Speech-first audio: lifts the centre channel when downmixing (film
    /// dialogue lives there and sinks under effects in a plain stereo mix)
    /// and levels the volume so whispers and explosions land close together.
    @Published public var boostDialogue: Bool = false {
        didSet {
            UserDefaults.standard.set(boostDialogue, forKey: "LerzoPlayer.boostDialogue")
            applyAudioFilters()
        }
    }
    /// Display-side picture correction (mpv equalizer, −100…100). A
    /// preference rather than a per-file value: it compensates for the
    /// monitor and the room, not for the file.
    @Published public var brightness: Double = 0 { didSet { applyPictureSetting("brightness", brightness) } }
    @Published public var contrast: Double = 0 { didSet { applyPictureSetting("contrast", contrast) } }
    @Published public var saturation: Double = 0 { didSet { applyPictureSetting("saturation", saturation) } }
    @Published public var gamma: Double = 0 { didSet { applyPictureSetting("gamma", gamma) } }
    public static let pictureRange = -100.0...100.0
    public var hasPictureAdjustments: Bool { brightness != 0 || contrast != 0 || saturation != 0 || gamma != 0 }
    private static let dialogueFilterChain =
        "lavfi=[pan=stereo|FL=FL+1.5*FC+0.6*BL+0.6*SL|FR=FR+1.5*FC+0.6*BR+0.6*SR,dynaudnorm=f=250:g=9:p=0.9:m=10]"
    /// Pass HDR video through to the display as HDR (EDR) instead of
    /// tone-mapping it to SDR. Only takes effect on displays that support EDR.
    @Published public var hdrOutputEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(hdrOutputEnabled, forKey: "LerzoPlayer.hdrOutputEnabled")
            updateHDROutput()
        }
    }
    /// Whether the screen the player window is on can show EDR/HDR content.
    @Published public private(set) var displaySupportsHDR: Bool = false
    /// True while the current video is HDR (PQ or HLG transfer).
    @Published public private(set) var isHDRContent: Bool = false
    /// True from releasing Tab until mpv confirms playback resumed. The UI
    /// keeps the controls hidden during this gap so they do not flash.
    @Published public private(set) var isResumingAfterPeek = false
    /// When playback last resumed because Tab was released. Lets the UI tell
    /// this resume apart from one that should reveal the controls.
    public private(set) var lastPeekResumeDate: Date = .distantPast
    /// True once mpv's window is embedded under the transparent SwiftUI window.
    /// Until then the UI must paint its own background, or the desktop shows through.
    @Published public var hasVideoSurface: Bool = false
    
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
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: Self.subFontSizeKey) as? Double {
            self.subFontSize = saved
        } else if let legacy = defaults.object(forKey: Self.legacySubFontSizeKey) as? Double, legacy > 15 {
            // Convert the old nominal value to the size that was actually drawn.
            self.subFontSize = min(max((legacy * 0.65).rounded(), Self.subFontSizeRange.lowerBound), Self.subFontSizeRange.upperBound)
            defaults.set(self.subFontSize, forKey: Self.subFontSizeKey)
            defaults.removeObject(forKey: Self.legacySubFontSizeKey)
        }
        if let saved = UserDefaults.standard.string(forKey: "LerzoPlayer.translationMode")
            .flatMap(TranslationMode.init(rawValue:)) {
            self.translationMode = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "LerzoPlayer.pauseWhilePeeking") as? Bool {
            self.pauseWhilePeeking = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "LerzoPlayer.hdrOutputEnabled") as? Bool {
            self.hdrOutputEnabled = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "LerzoPlayer.boostDialogue") as? Bool {
            self.boostDialogue = saved
        }
        self.brightness = defaults.double(forKey: "LerzoPlayer.picture.brightness")
        self.contrast = defaults.double(forKey: "LerzoPlayer.picture.contrast")
        self.saturation = defaults.double(forKey: "LerzoPlayer.picture.saturation")
        self.gamma = defaults.double(forKey: "LerzoPlayer.picture.gamma")
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
        let screen = view.window?.screen ?? NSScreen.main
        self.displaySupportsHDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
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
        
        Self.pointVulkanLoaderAtBundledMoltenVK()
        guard let handle = mpv_create() else {
            return
        }
        self.mpv = handle
        
        // Debugging aid: VPLAYER_MPV_LOG=/path/to/file writes mpv's verbose log.
        if let logPath = ProcessInfo.processInfo.environment["VPLAYER_MPV_LOG"], !logPath.isEmpty {
            mpv_set_option_string(handle, "log-file", logPath)
            mpv_set_option_string(handle, "msg-level", "all=v")
        }
        
        // 1. Embedded options to prevent hook hanging and detached separate window
        mpv_set_option_string(handle, "hwdec", "auto")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        // Builtin Lua scripts ignore load-scripts. They are useless here (the UI
        // is ours) and LuaJIT's generated code gets the process killed under
        // the hardened runtime of a signed release build.
        for script in ["osd-console", "select", "positioning", "context-menu", "commands", "stats-overlay", "auto-profiles"] {
            mpv_set_option_string(handle, "load-\(script)", "no")
        }
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
        
        // HDR passthrough: with the hint enabled, gpu-next/macvk switches the
        // Metal layer to BT.2100 PQ (EDR) for HDR sources and keeps SDR
        // sources in BT.709, so it is safe to leave on whenever the display
        // supports EDR. Without it every HDR file is tone-mapped to SDR.
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "target-colorspace-hint", shouldOutputHDR ? "yes" : "no")
        
        // 2. High quality video & audio defaults
        mpv_set_option_string(handle, "keep-open", "yes")
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double {
            volume = saved
            mpv_set_option_string(handle, "volume", "\(Int(saved.rounded()))")
        }
        mpv_set_option_string(handle, "sub-auto", "fuzzy")
        mpv_set_option_string(handle, "secondary-sub-visibility", "no")
        
        // 3. Initialize
        let initStatus = mpv_initialize(handle)
        if initStatus < 0 {
            return
        }
        
        // 4. Apply subtitle styling defaults
        applySubtitleStyle()
        applyAudioFilters()
        applyPictureSettings()
        
        // 5. Observe properties
        observeProperties(handle)
        
        // 6. Start event loop thread
        isRunning = true
        eventThread = Thread { [weak self] in
            self?.runEventLoop()
        }
        eventThread?.name = "LerzoPlayer.MPVEventThread"
        eventThread?.start()
    }
    
    private func destroyMPV() {
        embedTimer?.invalidate()
        embedTimer = nil
        if let child = mpvChildWindow {
            targetView?.window?.removeChildWindow(child)
            child.orderOut(nil)
            self.mpvChildWindow = nil
            self.hasVideoSurface = false
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
        mpv_observe_property(handle, 14, "video-params/gamma", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 15, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 16, "sub-delay", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 17, "secondary-sub-delay", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 18, "audio-delay", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 19, "video-zoom", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 20, "video-pan-x", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 21, "video-pan-y", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 22, "panscan", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 23, "video-crop", MPV_FORMAT_STRING)
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
    
    /// A release bundle ships MoltenVK in Contents/Frameworks with an ICD
    /// manifest in Resources; the Vulkan loader only finds it through these
    /// variables. Dev builds have no manifest and keep using Homebrew's.
    private static func pointVulkanLoaderAtBundledMoltenVK() {
        guard let manifest = Bundle.main.resourceURL?
                .appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json"),
              FileManager.default.fileExists(atPath: manifest.path) else { return }
        setenv("VK_DRIVER_FILES", manifest.path, 1)   // loader ≥ 1.3.207
        setenv("VK_ICD_FILENAMES", manifest.path, 1)  // older loaders
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
    
    /// The `af` option is global, so it survives file changes on its own.
    private func applyAudioFilters() {
        setPropertyAsync("af", boostDialogue ? Self.dialogueFilterChain : "")
    }

    private func applyPictureSetting(_ property: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: "LerzoPlayer.picture.\(property)")
        setPropertyAsync(property, "\(Int(value.rounded()))")
    }

    private func applyPictureSettings() {
        for (property, value) in [("brightness", brightness), ("contrast", contrast), ("saturation", saturation), ("gamma", gamma)] {
            setPropertyAsync(property, "\(Int(value.rounded()))")
        }
    }

    public func resetPictureAdjustments() {
        brightness = 0; contrast = 0; saturation = 0; gamma = 0
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
                    window.collectionBehavior = Self.embeddedWindowBehavior

                    self.configureEmbeddedWindow(window, in: parentWindow)
                    window.setFrame(self.embeddedWindowFrame(for: parentWindow), display: true)
                    self.updateEmbeddedWindowOrdering(window, in: parentWindow)
                    self.mpvChildWindow = window
                    self.hasVideoSurface = true
                    self.updateOverlayEDRFlag()
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
            if child.collectionBehavior != Self.embeddedWindowBehavior {
                child.collectionBehavior = Self.embeddedWindowBehavior
            }
            child.ignoresMouseEvents = true
            child.hasShadow = false
            
            self.configureEmbeddedWindow(child, in: parent)
            // SwiftUI can rebuild the overlay's layer tree (e.g. when the
            // background switches to clear once video appears), dropping the
            // EDR flag; re-assert it on every geometry pass.
            self.updateOverlayEDRFlag()
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
                if parent.isOnActiveSpace {
                    child.order(.below, relativeTo: parent.windowNumber)
                }
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

    /// The video window must never be on every desktop (`.canJoinAllSpaces`
    /// showed the picture on other Spaces, and everywhere in fullscreen).
    /// It rides along as a child window, and while detached in fullscreen
    /// `.moveToActiveSpace` lets it be pulled onto the fullscreen Space.
    private static let embeddedWindowBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

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
            // Only reorder while the fullscreen Space is the active one:
            // `.moveToActiveSpace` would otherwise drag the video onto
            // whatever desktop the user swiped to. A detached window left on
            // another Space is ordered out and back in to relocate it.
            if parent.isOnActiveSpace {
                if !child.isOnActiveSpace {
                    child.orderOut(nil)
                }
                child.order(.below, relativeTo: parent.windowNumber)
            }
        } else {
            NSApp.presentationOptions = []
            child.level = .normal
            parent.level = .normal
            if !isAttached {
                parent.addChildWindow(child, ordered: .below)
            }
        }
    }
    
    // MARK: - HDR Output
    private var shouldOutputHDR: Bool {
        hdrOutputEnabled && displaySupportsHDR
    }

    /// Re-evaluates EDR support for the screen the window is on and pushes
    /// the resulting hint to mpv. Call when the window changes screens.
    public func updateHDROutput() {
        let apply = { [weak self] in
            guard let self else { return }
            let screen = self.targetView?.window?.screen ?? NSScreen.main
            let supports = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
            if self.displaySupportsHDR != supports {
                self.displaySupportsHDR = supports
            }
            self.setPropertyAsync("target-colorspace-hint", self.shouldOutputHDR ? "yes" : "no")
            self.updateOverlayEDRFlag()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// The video lives in mpv's own window underneath the transparent SwiftUI
    /// window. The compositor only engages EDR for a window that is not
    /// covered by another one, and it counts that overlay as cover, so HDR
    /// content stayed tone-mapped. Declaring EDR on the overlay's own layer
    /// lifts that — but only while HDR is actually being shown, so SDR
    /// playback never pushes the display into HDR mode.
    private func updateOverlayEDRFlag() {
        guard let window = targetView?.window else { return }
        let wantsEDR = isHDRContent && shouldOutputHDR
        window.contentView?.wantsLayer = true
        for layer in [window.contentView?.layer, targetView?.layer].compactMap({ $0 })
        where layer.wantsExtendedDynamicRangeContent != wantsEDR {
            layer.wantsExtendedDynamicRangeContent = wantsEDR
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
        self.subtitleTimeline = nil
        self.subtitleTimelineKey = nil
        self.subtitleTimelineCache.removeAll()
        clearLoop()
        autoPausedCueIndex = nil
        pendingAutoPause = nil
        autoPauseTail = 0
        
        guard mpv != nil, targetView?.window != nil else {
            return
        }
        
        startEmbeddingPolling()
        
        setPropertyAsync("pause", "no")
        setPropertyAsync("speed", "1")
        for stream in DelayStream.allCases {
            setPropertyAsync(stream.property, "0")
        }
        resetVideoGeometry()
        executeCommand(["loadfile", url.path, "replace"])
    }
    
    public func togglePlayPause() {
        isAutoPaused = false
        pendingAutoPause = nil
        if playbackState == .finished {
            restartFromBeginning()
            return
        }
        executeCommand(["cycle", "pause"])
    }
    
    public func play() {
        isAutoPaused = false
        // Resuming past a line's end means going on, not pausing for it.
        pendingAutoPause = nil
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
        isAutoPaused = false
        setPropertyAsync("pause", "yes")
    }
    
    /// A user seek (scrubbing, jumping): leaving the line ends a line loop.
    public func seek(to seconds: Double) {
        if isLoopingLine { clearLoop() }
        performSeek(to: seconds)
    }

    private func performSeek(to seconds: Double) {
        let sec = max(0, min(seconds, duration))
        beginSeek(optimisticTime: sec)
        executeCommand(["seek", "\(sec)", "absolute+exact"])
    }
    
    public func seekRelative(seconds: Double) {
        if isLoopingLine { clearLoop() }
        beginSeek(optimisticTime: max(0, min(currentTime + seconds, duration)))
        executeCommand(["seek", "\(seconds)", "relative"])
    }
    
    /// `direction` is a line count, `sub-seek` style: 0 replays the current
    /// line, ±1 jumps to the next / previous one. Uses the track's own cue
    /// list when it is known; mpv's `sub-seek` only sees the events already
    /// decoded, so with embedded subtitles it cannot jump ahead reliably.
    public func seekSubtitle(direction: Int) {
        if let timeline = subtitleTimeline, !timeline.cues.isEmpty {
            // Subtitle clock -> video clock: a cue starting at s shows at s + sub-delay.
            if let target = timeline.seekTargetIndex(from: currentTime - subDelay, skip: direction) {
                // A line loop follows the line the user moves to.
                if isLoopingLine { bindLineLoop(to: target) }
                performSeek(to: timeline.cues[target].start + subDelay)
                resumeAfterLineJump(direction: direction)
            }
            return
        }
        beginSeek(optimisticTime: nil)
        executeCommand(["sub-seek", "\(direction)"])
        resumeAfterLineJump(direction: direction)
    }

    /// Replaying a line means hearing it, so R always plays. W/E play on
    /// only from an auto-pause ("next" there means "go on"); a pause the user
    /// made themselves stays while they browse the lines.
    private func resumeAfterLineJump(direction: Int) {
        guard playbackState == .paused, direction == 0 || isAutoPaused else { return }
        play()
    }

    // MARK: - Line auto-pause and loops

    /// Called with every `time-pos` update. Pauses as soon as the line that
    /// was on screen at the previous tick has ended, when auto-pause is on;
    /// a loop makes that moot (mpv jumps back to the line's start on its
    /// own). Pausing on the first tick past the end, rather than a little
    /// before it, keeps the last syllable from being cut off.
    private func checkLineEnd(at time: Double) {
        guard autoPauseAfterLine, loopMode == .off, let timeline = subtitleTimeline else {
            lineUnderPlayback = nil
            pendingAutoPause = nil
            return
        }
        let subTime = time - subDelay
        let current = timeline.index(containing: subTime)
        if let ended = lineUnderPlayback, ended != current, ended != autoPausedCueIndex,
           subTime >= timeline.cues[ended].end {
            pendingAutoPause = (ended, timeline.cues[ended].end + subDelay + autoPauseTail)
        }
        lineUnderPlayback = current
        guard playbackState == .playing, let pending = pendingAutoPause, time >= pending.at else { return }
        pendingAutoPause = nil
        autoPausedCueIndex = pending.cueIndex
        pause()
        isAutoPaused = true
        // Keep the line readable unless the next one is already on screen.
        if current == nil {
            let translation = translationSeen?.cueIndex == pending.cueIndex ? translationSeen?.text ?? "" : ""
            heldLine = (timeline.cues[pending.cueIndex].text, translation)
        }
    }

    public func adjustAutoPauseTail(by delta: Double) {
        setAutoPauseTail(autoPauseTail + delta)
    }

    public func setAutoPauseTail(_ seconds: Double) {
        let clamped = min(max(seconds, Self.autoPauseTailRange.lowerBound), Self.autoPauseTailRange.upperBound)
        autoPauseTail = (clamped * 10).rounded() / 10
    }

    /// Repeat the line on screen (or the last one shown) until turned off.
    /// W/E/R move the loop to the new line; any other seek ends it.
    public func toggleLineLoop() {
        if isLoopingLine {
            clearLoop()
            return
        }
        guard let timeline = subtitleTimeline,
              let index = timeline.currentIndex(at: currentTime - subDelay) else { return }
        bindLineLoop(to: index)
        // Past the line's end (in the gap before the next one) mpv would loop
        // back only once it notices; start it over ourselves.
        if currentTime - subDelay >= timeline.cues[index].end {
            performSeek(to: timeline.cues[index].start + subDelay)
        }
    }

    private func bindLineLoop(to index: Int) {
        guard let cue = subtitleTimeline?.cues[index] else { return }
        loopMode = .line(cueIndex: index)
        setLoopPoints(a: cue.start + subDelay, b: cue.end + subDelay)
    }

    /// mpv's own A–B loop: the first call marks the start at the current
    /// position, the second the end (and starts looping), the third clears.
    public func cycleABLoop() {
        switch loopMode {
        case .ab(let a, nil) where currentTime > a + 0.5:
            loopMode = .ab(a: a, b: currentTime)
            setLoopPoints(a: a, b: currentTime)
        case .ab(_, .some):
            clearLoop()
        default:
            // Fresh start, a line loop, or an end no later than the start.
            loopMode = .ab(a: currentTime, b: nil)
            setLoopPoints(a: currentTime, b: nil)
        }
    }

    public func clearLoop() {
        guard loopMode != .off else { return }
        loopMode = .off
        setLoopPoints(a: nil, b: nil)
    }

    private func setLoopPoints(a: Double?, b: Double?) {
        setPropertyAsync("ab-loop-a", a.map { "\($0)" } ?? "no")
        setPropertyAsync("ab-loop-b", b.map { "\($0)" } ?? "no")
    }

    /// Reads the primary subtitle track's cues in the background (a full
    /// sequential scan of the file), keeping them per track for this file.
    private func updateSubtitleTimeline() {
        guard let track = subtitleTracks.first(where: { $0.id == currentPrimarySubId }),
              let ffIndex = track.ffIndex,
              let path = track.externalFilename ?? currentFileURL?.path else {
            subtitleTimeline = nil
            subtitleTimelineKey = nil
            return
        }
        let key = "\(path)#\(ffIndex)"
        guard key != subtitleTimelineKey else { return }
        subtitleTimelineKey = key
        subtitleTimeline = subtitleTimelineCache[key]
        // Unreadable tracks are cached as an empty timeline, so this also
        // stops us from rescanning them.
        guard subtitleTimeline == nil, !subtitleTimelinesLoading.contains(key) else { return }
        subtitleTimelinesLoading.insert(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let timeline = SubtitleTimeline.load(path: path, streamIndex: ffIndex)
            DispatchQueue.main.async {
                guard let self else { return }
                self.subtitleTimelinesLoading.remove(key)
                // Bitmap subtitles: an empty timeline makes seekSubtitle fall
                // back to mpv, which does handle them within its window.
                let loaded = timeline ?? SubtitleTimeline(cues: [])
                self.subtitleTimelineCache[key] = loaded
                if self.subtitleTimelineKey == key {
                    self.subtitleTimeline = loaded
                }
            }
        }
    }

    private func beginSeek(optimisticTime: Double?) {
        // Must apply synchronously when called from the UI: the caller's next
        // state change (e.g. dropping the scrub value) renders in the same
        // frame, and an async update would let a stale currentTime flash first.
        let apply = { [weak self] in
            guard let self else { return }
            self.isSeekInFlight = true
            // Replaying a line should pause at its end again; and the line
            // under playback is whatever we land on, not the one we left.
            self.autoPausedCueIndex = nil
            self.lineUnderPlayback = nil
            self.pendingAutoPause = nil
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

    // MARK: - Playback Speed
    public func setSpeed(_ value: Double) {
        let clamped = min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        // Snap to the 0.1 grid so repeated +/- steps do not drift (0.7000001).
        let snapped = (clamped / Self.speedStep).rounded() * Self.speedStep
        setPropertyAsync("speed", String(format: "%.2f", snapped))
    }

    public func adjustSpeed(by delta: Double) {
        setSpeed(playbackSpeed + delta)
    }

    public func resetSpeed() {
        setSpeed(1.0)
    }

    // MARK: - Delays
    public enum DelayStream: CaseIterable {
        case subtitle, secondarySubtitle, audio

        var property: String {
            switch self {
            case .subtitle: return "sub-delay"
            case .secondarySubtitle: return "secondary-sub-delay"
            case .audio: return "audio-delay"
            }
        }
    }

    public func delay(of stream: DelayStream) -> Double {
        switch stream {
        case .subtitle: return subDelay
        case .secondarySubtitle: return secondarySubDelay
        case .audio: return audioDelay
        }
    }

    public func setDelay(_ value: Double, of stream: DelayStream) {
        let clamped = min(max(value, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        // Snap to the step grid so repeated +/- presses do not drift (0.30000001).
        let snapped = (clamped / Self.delayStep).rounded() * Self.delayStep
        setPropertyAsync(stream.property, String(format: "%.3f", snapped))
    }

    public func adjustDelay(of stream: DelayStream, by delta: Double) {
        setDelay(delay(of: stream) + delta, of: stream)
    }

    public func resetDelay(of stream: DelayStream) {
        setDelay(0, of: stream)
    }
    
    // MARK: - Video Geometry (zoom, pan, fill, crop)
    /// Zoom as the user sees it: 1.0 = 100 %.
    public var zoomScale: Double { pow(2, videoZoom) }

    /// Steps are linear in percent (100 → 102 → 104), not in mpv's log scale,
    /// because that is what the OSD shows and what feels even to the eye.
    public func setZoom(scale: Double) {
        let clamped = min(max(scale, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let snapped = (clamped * 100).rounded() / 100
        setPropertyAsync("video-zoom", String(format: "%.4f", log2(snapped)))
    }

    public func adjustZoom(by delta: Double) {
        setZoom(scale: zoomScale + delta)
    }

    /// Moves the picture by a fraction of its scaled size; positive dx/dy = right/down.
    public func pan(dx: Double, dy: Double) {
        let x = (((videoPanX + dx) / Self.panStep).rounded() * Self.panStep)
        let y = (((videoPanY + dy) / Self.panStep).rounded() * Self.panStep)
        setPropertyAsync("video-pan-x", String(format: "%.3f", min(max(x, -1), 1)))
        setPropertyAsync("video-pan-y", String(format: "%.3f", min(max(y, -1), 1)))
    }

    public func resetZoomAndPan() {
        setPropertyAsync("video-zoom", "0")
        setPropertyAsync("video-pan-x", "0")
        setPropertyAsync("video-pan-y", "0")
    }

    public func setFillsWindow(_ fill: Bool) {
        setPropertyAsync("panscan", fill ? "1" : "0")
    }

    public func resetCrop() {
        setPropertyAsync("video-crop", "")
    }

    /// Everything the Video menu touches, back to defaults.
    public func resetVideoGeometry() {
        resetZoomAndPan()
        setPropertyAsync("panscan", "0")
        resetCrop()
    }

    public enum CropResult: Equatable {
        case cropped, nothingToCrop, failed
    }

    /// Measures the black bars baked into the current frame and crops them
    /// away with `video-crop`. Works on a raw frame grabbed from mpv, so it
    /// does not care whether decoding is hardware-accelerated (a cropdetect
    /// filter would). Any earlier crop is dropped first, so the measurement
    /// is always against the full source picture.
    public func removeBlackBars(completion: @escaping (CropResult) -> Void) {
        guard let handle = mpv, currentFileURL != nil else { completion(.failed); return }
        let hadCrop = !videoCrop.isEmpty
        if hadCrop {
            resetCrop()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (hadCrop ? 0.3 : 0)) {
            guard let frame = Self.grabRawFrame(handle) else {
                DispatchQueue.main.async { completion(.failed) }
                return
            }
            var srcW: Int64 = 0, srcH: Int64 = 0
            mpv_get_property(handle, "width", MPV_FORMAT_INT64, &srcW)
            mpv_get_property(handle, "height", MPV_FORMAT_INT64, &srcH)
            guard srcW > 0, srcH > 0, let bars = Self.detectContentRect(in: frame) else {
                DispatchQueue.main.async { completion(.failed) }
                return
            }
            // The frame may come back at a different size than the source;
            // scale the rectangle into source pixels, which video-crop expects.
            let sx = Double(srcW) / Double(frame.width), sy = Double(srcH) / Double(frame.height)
            // Even offsets and sizes (chroma subsampling), erring towards the
            // inside: a pixel of picture lost is invisible, a pixel of bar is not.
            let x = (Int((Double(bars.minX) * sx).rounded(.up)) + 1) & ~1
            let y = (Int((Double(bars.minY) * sy).rounded(.up)) + 1) & ~1
            let w = min(Int(srcW) - x, Int((Double(bars.maxX) * sx).rounded(.down)) & ~1 - x)
            let h = min(Int(srcH) - y, Int((Double(bars.maxY) * sy).rounded(.down)) & ~1 - y)
            let trimmed = Double(w * h) / Double(srcW * srcH)
            DispatchQueue.main.async { [weak self] in
                guard trimmed < 0.98 else { completion(.nothingToCrop); return }
                self?.setPropertyAsync("video-crop", "\(w)x\(h)+\(x)+\(y)")
                completion(.cropped)
            }
        }
    }

    private struct RawFrame {
        let width: Int, height: Int, stride: Int
        let pixels: [UInt8]   // bgr0 / bgra, 4 bytes per pixel
    }

    /// `screenshot-raw video`: the current frame without subtitles or OSD.
    private static func grabRawFrame(_ handle: OpaquePointer) -> RawFrame? {
        var result = mpv_node()
        let args: [String] = ["screenshot-raw", "video"]
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        defer { for ptr in cArgs where ptr != nil { free(UnsafeMutableRawPointer(mutating: ptr)) } }
        guard mpv_command_ret(handle, &cArgs, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list else { return nil }

        var w = 0, h = 0, stride = 0
        var format = ""
        var bytes: [UInt8]? = nil
        for i in 0..<Int(list.pointee.num) {
            let key = String(cString: list.pointee.keys[i]!)
            let value = list.pointee.values[i]
            switch key {
            case "w": w = Int(value.u.int64)
            case "h": h = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "format": if value.format == MPV_FORMAT_STRING { format = String(cString: value.u.string) }
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let ba = value.u.ba {
                    bytes = Array(UnsafeBufferPointer(start: ba.pointee.data.assumingMemoryBound(to: UInt8.self), count: ba.pointee.size))
                }
            default: break
            }
        }
        guard w > 0, h > 0, stride >= w * 4, let pixels = bytes, pixels.count >= stride * h,
              format == "bgr0" || format == "bgra" || format == "rgba" else { return nil }
        return RawFrame(width: w, height: h, stride: stride, pixels: pixels)
    }

    /// Bounding box of the non-black picture: a row or column counts as a
    /// bar when almost all of its pixels are darker than `threshold`.
    private static func detectContentRect(in frame: RawFrame) -> CGRect? {
        let threshold: UInt8 = 32   // above codec ringing at the bar edge, below any real picture
        let tolerance = 0.02   // share of bright pixels a bar row may still contain (noise, logos)
        let px = frame.pixels

        func isBright(_ x: Int, _ y: Int) -> Bool {
            let i = y * frame.stride + x * 4
            return px[i] > threshold || px[i + 1] > threshold || px[i + 2] > threshold
        }
        func rowIsBlack(_ y: Int) -> Bool {
            var bright = 0
            let limit = Int(Double(frame.width) * tolerance)
            for x in 0..<frame.width where isBright(x, y) {
                bright += 1
                if bright > limit { return false }
            }
            return true
        }
        func columnIsBlack(_ x: Int) -> Bool {
            var bright = 0
            let limit = Int(Double(frame.height) * tolerance)
            for y in 0..<frame.height where isBright(x, y) {
                bright += 1
                if bright > limit { return false }
            }
            return true
        }

        var top = 0, bottom = frame.height - 1, left = 0, right = frame.width - 1
        while top < bottom && rowIsBlack(top) { top += 1 }
        while bottom > top && rowIsBlack(bottom) { bottom -= 1 }
        guard bottom - top > frame.height / 4 else { return nil }   // black frame: nothing to measure
        while left < right && columnIsBlack(left) { left += 1 }
        while right > left && columnIsBlack(right) { right -= 1 }
        guard right - left > frame.width / 4 else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    // MARK: - Language Learning & Subtitle Methods
    /// The translation text comes from mpv's `secondary-sub-text` no matter
    /// what `secondary-sub-visibility` says (that only affects mpv's own,
    /// hidden rendering), so showing it is purely a SwiftUI concern.
    public func setPeekingTranslation(_ isPeeking: Bool) {
        // Tab auto-repeats while held; only react to actual transitions.
        guard isPeeking != isPeekingTranslation else { return }
        self.isPeekingTranslation = isPeeking

        if isPeeking {
            // With the translation already pinned, TAB has nothing to reveal;
            // and pausing for a "no translation track" hint would only annoy.
            let peekReveals = translationMode == .peek && translationUnavailableReason == nil
            if peekReveals && pauseWhilePeeking && playbackState == .playing {
                didPauseForPeek = true
                pause()
            }
        } else if didPauseForPeek {
            didPauseForPeek = false
            // Only resume what we paused; leave a manual pause made meanwhile alone.
            if playbackState == .paused {
                isResumingAfterPeek = true
                lastPeekResumeDate = Date()
                play()
                // Safety net in case mpv never reports the unpause.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.isResumingAfterPeek = false
                }
            }
        }
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
    
    /// File extensions treated as subtitle files when opened or dropped.
    public static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    /// Opens a video, or adds a subtitle file to the current video.
    public func open(url: URL) {
        if Self.subtitleExtensions.contains(url.pathExtension.lowercased()) {
            loadExternalSubtitle(fileURL: url)
        } else {
            loadFile(url: url)
        }
    }

    public func loadExternalSubtitle(fileURL: URL) {
        guard currentFileURL != nil else { return }
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
                    self?.autoSelectTracksForLanguages()
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
                    self.checkLineEnd(at: time)
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
                    if !isPaused {
                        self.isResumingAfterPeek = false
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

        case "speed":
            if let data = prop.data {
                let speed = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    self?.playbackSpeed = speed
                }
            }

        case "video-zoom", "video-pan-x", "video-pan-y", "panscan":
            if let data = prop.data {
                let value = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch propName {
                    case "video-zoom": self.videoZoom = value
                    case "video-pan-x": self.videoPanX = value
                    case "video-pan-y": self.videoPanY = value
                    default: self.fillsWindow = value > 0.5
                    }
                }
            }

        case "video-crop":
            var crop = ""
            if let data = prop.data, let cStr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                crop = String(cString: cStr)
            }
            DispatchQueue.main.async { [weak self] in
                self?.videoCrop = crop
            }

        case "sub-delay", "secondary-sub-delay", "audio-delay":
            if let data = prop.data {
                let delay = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch propName {
                    case "sub-delay": self.subDelay = delay
                    case "secondary-sub-delay": self.secondarySubDelay = delay
                    default: self.audioDelay = delay
                    }
                }
            }
            
        case "mute":
            if let data = prop.data {
                let muted = data.assumingMemoryBound(to: Int32.self).pointee != 0
                DispatchQueue.main.async { [weak self] in
                    self?.isMuted = muted
                }
            }
            
        case "video-params/gamma":
            var gamma = ""
            if let data = prop.data {
                gamma = String(cString: data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee)
            }
            let isHDR = gamma == "pq" || gamma == "hlg"
            DispatchQueue.main.async { [weak self] in
                self?.isHDRContent = isHDR
                self?.updateOverlayEDRFlag()
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
                guard let self else { return }
                self.currentSecondarySubText = text
                if !text.isEmpty, let line = self.lineUnderPlayback {
                    self.translationSeen = (line, text)
                }
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
            let isForced = getTrackFlag(handle, idx: i, prop: "forced")
            let ffIndex = getTrackInt(handle, idx: i, prop: "ff-index").map { Int($0) }
            let externalFilename = isExt ? getTrackProp(handle, idx: i, prop: "external-filename") : nil
            
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
                                          isExternal: isExt,
                                          isForced: isForced,
                                          ffIndex: ffIndex,
                                          externalFilename: externalFilename))
            }
        }
        
        self.audioTracks = newAudios
        self.subtitleTracks = newSubs
        self.currentAudioTrackId = selectedAudioID ?? newAudios.first(where: \.isSelected)?.id
        self.currentPrimarySubId = selectedPrimarySubID
        self.currentSecondarySubId = selectedSecondarySubID
        // The track list may have arrived after the selection did.
        if subtitleTimeline == nil {
            updateSubtitleTimeline()
        }
    }
    
    /// Applies the language preferences to the freshly loaded file: audio and
    /// primary subtitles in the learning language, secondary subtitles in the
    /// native language. Roles without a matching track keep mpv's defaults.
    public func autoSelectTracksForLanguages() {
        let prefs = LanguagePreferences.shared

        var primary: MediaTrack?
        if let learning = prefs.resolvedLearningCode {
            if let audio = LanguagePreferences.bestTrack(in: audioTracks, matching: learning) {
                setAudioTrack(trackId: audio.id)
            }
            primary = LanguagePreferences.bestTrack(in: subtitleTracks, matching: learning)
            if let primary {
                setPrimarySubtitle(trackId: primary.id)
            }
        }

        if let native = prefs.resolvedNativeCode,
           let secondary = LanguagePreferences.bestTrack(in: subtitleTracks.filter { $0.id != primary?.id }, matching: native) {
            setSecondarySubtitle(trackId: secondary.id)
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
