import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var gemini = GeminiService.shared
    @ObservedObject private var cards = CardStore.shared
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var keyboardMonitor = KeyboardMonitor.shared
    
    @State private var showControls: Bool = true
    @State private var isSettingsOpen: Bool = false
    @State private var isExplanationOpen: Bool = false
    @State private var isShortcutsOpen: Bool = false
    @State private var selectedWordToExplain: String? = nil
    @State private var hideTimer: Timer? = nil
    /// Last measured height of the controls bar; kept while the bar is hidden
    /// so the subtitles do not drop when it goes away in the "always" mode.
    @State private var controlsBarHeight: CGFloat = 0
    @State private var topBarHeight: CGFloat = 0
    /// File whose "no subtitles" prompt the user closed; the prompt comes back
    /// for the next file that has no tracks either.
    @State private var dismissedNoSubtitlesURL: URL? = nil
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // LAYER 1: Native mpv video surface
            PlayerSurfaceView(onMouseMove: {
                wakeControls()
            })
            .ignoresSafeArea()
            
            // LAYER 2: Empty State / Dropzone when no file is playing
            if player.playbackState == .idle && player.currentFileURL == nil {
                emptyStateView
            }
            
            // LAYER 3: Loading Indicator (only while loading a file)
            if player.playbackState == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .colorInvert()
                    Text("Loading video...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.75))
                )
                .transition(.opacity)
            }
            
            // Keyboard feedback (speed, volume, seek) in the top-left corner.
            OSDView()

            // Controls are hidden while peeking the translation: the peek pause
            // would otherwise pop the controls and the big play button over the text.
            let controlsWanted = showControls || player.playbackState == .paused || player.playbackState == .finished || player.playbackState == .idle
            let controlsShown = controlsWanted && !player.isPeekingTranslation && !player.isResumingAfterPeek

            // Controls backdrop: under the subtitles so it never dims them.
            if controlsShown {
                ControlsBackdropView()
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // LAYER 4: Interactive Subtitles Layer
            SubtitlesLayer(
                showExplanation: $isExplanationOpen,
                controlsBarHeight: controlsBarHeight,
                topBarHeight: topBarHeight,
                controlsShown: controlsShown,
                onExplainWord: { word in
                    player.pause()
                    selectedWordToExplain = word
                    isExplanationOpen = true
                }
            )
            .allowsHitTesting(true)
            
            // LAYER 5: Floating Controls Overlay
            if controlsShown {
                ControlsOverlayView(
                    isSettingsOpen: $isSettingsOpen,
                    isExplanationOpen: $isExplanationOpen,
                    isShortcutsOpen: $isShortcutsOpen,
                    onOpenFile: openFileDialog
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // A loaded video with no subtitle tracks needs a different empty
            // state from the welcome screen. Keep it with the controls so it
            // disappears during uninterrupted watching and returns on hover,
            // and let the user close it for good when the file simply has none.
            let noSubtitlesDismissed = player.currentFileURL != nil && dismissedNoSubtitlesURL == player.currentFileURL
            if showsVideo && player.subtitleTracks.isEmpty && controlsShown && !noSubtitlesDismissed {
                VStack {
                    noSubtitlesView
                        .padding(.top, max(topBarHeight + 16, 72))
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Above the full-window controls overlay so its Export button is
            // always clickable at EOF.
            if player.playbackState == .finished {
                let count = cards.newCount(for: player.currentFileURL)
                if count > 0 {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack.fill")
                                .foregroundColor(.yellow)
                            Text(count == 1 ? "1 new card" : "\(count) new cards")
                                .font(.system(size: 13, weight: .semibold))
                            Button("Export  (⌘E)") { openWindow(id: CardsWindow.windowID) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                        .shadow(radius: 10)
                        .padding(.bottom, max(controlsBarHeight + 18, 78))
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Keyboard cheat sheet (H)
            if isShortcutsOpen {
                ShortcutsOverlayView(isOpen: $isShortcutsOpen)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            
            // LAYER 6: Gemini AI Explanation Popover
            if isExplanationOpen {
                ExplanationPopoverView(
                    isOpen: $isExplanationOpen,
                    isSettingsOpen: $isSettingsOpen,
                    focusedWord: selectedWordToExplain
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExplanationOpen)
            }
        }
        // Dictionary card over the clicked word, above the controls and the
        // big play button; the word's bounds arrive from the subtitles layer.
        .overlayPreferenceValue(LookupAnchorsKey.self) { anchors in
            if let anchor = anchors.word {
                DictionaryCardOverlay(anchor: anchor, blockAnchor: anchors.block) { word in
                    player.pause()
                    selectedWordToExplain = word
                    isExplanationOpen = true
                }
            }
        }
        // Taller for the welcome screen, low enough for a wide picture at the
        // minimum width once a video is loaded (see MPVPlayer.windowMinSize).
        .frame(minWidth: player.windowMinSize.width, maxWidth: .infinity,
               minHeight: player.windowMinSize.height, maxHeight: .infinity)
        .onPreferenceChange(ControlsBarHeightKey.self) { height in
            // The preference resets to 0 when the overlay leaves the tree.
            if height > 0 { controlsBarHeight = height }
        }
        .onPreferenceChange(TopBarHeightKey.self) { height in
            if height > 0 { topBarHeight = height }
        }
        // The window itself is transparent (video renders in mpv's window
        // underneath), so paint a background until that surface exists and a
        // file is actually loaded; otherwise the desktop shows through.
        // Once video shows, the tint must stay just above zero: the window
        // server lets clicks fall through fully transparent pixels (seen in
        // fullscreen, where nothing of ours is underneath to catch them), so
        // clicking the video would not pause it.
        .background(showsVideo ? Color.black.opacity(0.01) : Color(red: 0.08, green: 0.08, blue: 0.1))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                wakeControls()
            case .ended:
                break
            }
        }
        .onAppear {
            setupKeyboardBindings()
            keyboardMonitor.isExplanationOpen = isExplanationOpen
            keyboardMonitor.isSettingsOpen = isSettingsOpen
            keyboardMonitor.isShortcutsOpen = isShortcutsOpen
        }
        .onChange(of: isShortcutsOpen) { _, isOpen in
            keyboardMonitor.isShortcutsOpen = isOpen
        }
        .onChange(of: player.playbackState) { _, state in
            // Playback can start without a mouse event (for example after opening
            // a file from Finder). Start the same timer so controls do not remain
            // pinned over a fullscreen video.
            // Resuming after a Tab peek is not such a case: the user was
            // reading, not reaching for the controls.
            if case .playing = state, Date().timeIntervalSince(player.lastPeekResumeDate) > 1.0 {
                wakeControls()
            }
        }
        .onChange(of: isExplanationOpen) { _, isOpen in
            keyboardMonitor.isExplanationOpen = isOpen
            if !isOpen {
                selectedWordToExplain = nil
            }
        }
        .onChange(of: isSettingsOpen) { _, isOpen in
            keyboardMonitor.isSettingsOpen = isOpen
        }
        .sheet(isPresented: $isSettingsOpen) {
            SettingsView(isOpen: $isSettingsOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
            isSettingsOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleShortcuts"))) { _ in
            keyboardMonitor.onToggleShortcutsRequested?()
        }
    }
    
    private var showsVideo: Bool {
        guard player.hasVideoSurface else { return false }
        switch player.playbackState {
        case .playing, .paused, .finished: return true
        case .idle, .loading: return false
        }
    }

    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "film.stack")
                    .font(.system(size: 44))
                    .foregroundColor(.yellow)
            }
            
            VStack(spacing: 6) {
                Text("Lerzo Player — a player for language learning")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Drop a movie here (MKV, MP4) or click the button below")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Button(action: openFileDialog) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                    Text("Choose a video...")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.yellow)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            
            // The three shortcuts that explain the learning workflow at a glance.
            HStack(spacing: 22) {
                shortcutBadge(keys: "R / W / E", text: "Replay / previous / next line")
                shortcutBadge(keys: "TAB", text: "Peek at the translation")
                shortcutBadge(keys: "⌘G", text: "AI phrase breakdown")
            }
            .padding(.top, 16)

            if !gemini.hasApiKey {
                Button(action: { isSettingsOpen = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                        Text("AI explanations need a free Gemini key — set it up in Settings")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.yellow.opacity(0.12))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
    
    private func shortcutBadge(keys: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: keys)
                .foregroundColor(.yellow)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private static let openSubtitlesURL = URL(string: "https://www.opensubtitles.com/en/home")!

    private var noSubtitlesView: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "captions.bubble")
                    .foregroundColor(.yellow)
                Text("No subtitle tracks were found")
                    .font(.system(size: 14, weight: .semibold))
            }

            Text("Load an SRT, ASS, or VTT file to make words clickable and use the learning tools.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                Button(action: openSubtitleDialog) {
                    Label("Load an external subtitle file", systemImage: "doc.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.yellow)
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Link("Find subtitles on OpenSubtitles ↗", destination: Self.openSubtitlesURL)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dismissedNoSubtitlesURL = player.currentFileURL
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Close"))
            .padding(4)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
    
    // MARK: - Auto Hide Controls
    private func wakeControls() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
        }
        NSCursor.setHiddenUntilMouseMoves(false)
        hideTimer?.invalidate()
        if player.playbackState == .playing && !isExplanationOpen {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
                if player.playbackState == .playing && !isExplanationOpen {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                    hidePointerOverVideo()
                }
            }
        }
    }

    /// The pointer goes away together with the controls, but only while it is
    /// over our window: the timer also runs when playback starts from Finder
    /// with the mouse parked over another app. Any movement brings it back.
    private func hidePointerOverVideo() {
        guard let window = NSApp.keyWindow, window.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
    
    private func setupKeyboardBindings() {
        keyboardMonitor.onExplainRequested = {
            self.selectedWordToExplain = nil
            self.isExplanationOpen = true
        }
        keyboardMonitor.onDismissExplanationRequested = {
            self.isExplanationOpen = false
            self.selectedWordToExplain = nil
            player.play()
        }
        keyboardMonitor.onOpenFileRequested = {
            self.openFileDialog()
        }
        keyboardMonitor.onOpenSubtitleRequested = {
            self.openSubtitleDialog()
        }
        keyboardMonitor.onOpenSettingsRequested = {
            self.isSettingsOpen = true
        }
        keyboardMonitor.onDismissSettingsRequested = {
            self.isSettingsOpen = false
        }
        keyboardMonitor.onToggleShortcutsRequested = {
            withAnimation(.easeOut(duration: 0.15)) {
                self.isShortcutsOpen.toggle()
            }
        }
        keyboardMonitor.onOpenCardsRequested = {
            self.openWindow(id: CardsWindow.windowID)
        }
    }
    
    private static let videoTypes: [UTType] = [
        UTType(filenameExtension: "mkv") ?? .movie,
        UTType(filenameExtension: "mp4") ?? .movie,
        UTType(filenameExtension: "mov") ?? .movie,
        UTType(filenameExtension: "avi") ?? .movie,
        UTType(filenameExtension: "webm") ?? .movie,
        UTType(filenameExtension: "m4v") ?? .movie,
        .movie,
        .video
    ]

    private static let subtitleTypes: [UTType] = MPVPlayer.subtitleExtensions.sorted().compactMap {
        UTType(filenameExtension: $0)
    }

    /// Videos, plus subtitle files once a video is loaded, so Cmd+O does
    /// both jobs.
    public func openFileDialog() {
        let subtitlesAllowed = player.currentFileURL != nil
        runOpenPanel(title: subtitlesAllowed ? String(localized: "Choose a video or subtitle file")
                                             : String(localized: "Choose a video file"),
                     types: Self.videoTypes + (subtitlesAllowed ? Self.subtitleTypes : []))
    }

    public func openSubtitleDialog() {
        guard player.currentFileURL != nil else { return }
        runOpenPanel(title: String(localized: "Choose a subtitle file"), types: Self.subtitleTypes)
    }

    private func runOpenPanel(title: String, types: [UTType]) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        
        if panel.runModal() == .OK, let url = panel.url {
            _ = url.startAccessingSecurityScopedResource()
            player.open(url: url)
        }
    }
}
