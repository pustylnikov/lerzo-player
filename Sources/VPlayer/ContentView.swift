import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject private var gemini = GeminiService.shared
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var keyboardMonitor = KeyboardMonitor.shared
    
    @State private var showControls: Bool = true
    @State private var isSettingsOpen: Bool = false
    @State private var isExplanationOpen: Bool = false
    @State private var isShortcutsOpen: Bool = false
    @State private var selectedWordToExplain: String? = nil
    @State private var hideTimer: Timer? = nil
    
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

            // LAYER 4: Interactive Subtitles Layer
            SubtitlesLayer(
                showExplanation: $isExplanationOpen,
                onExplainWord: { word in
                    player.pause()
                    selectedWordToExplain = word
                    isExplanationOpen = true
                }
            )
            .allowsHitTesting(true)
            
            // LAYER 5: Floating Controls Overlay
            // Hidden while peeking the translation: the peek pause would
            // otherwise pop the controls and the big play button over the text.
            let controlsWanted = showControls || player.playbackState == .paused || player.playbackState == .finished || player.playbackState == .idle
            if controlsWanted && !player.isPeekingTranslation && !player.isResumingAfterPeek {
                ControlsOverlayView(
                    isSettingsOpen: $isSettingsOpen,
                    isExplanationOpen: $isExplanationOpen,
                    isShortcutsOpen: $isShortcutsOpen,
                    onOpenFile: openFileDialog
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
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
                Text("VPlayer — a player for language learning")
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
            
            // Feature Highlights
            HStack(spacing: 24) {
                featureBadge(icon: "character.book.closed.fill", text: "TAB: peek at the translation")
                featureBadge(icon: "sparkles", text: "Gemini: idioms and slang explained")
                featureBadge(icon: "arrow.counterclockwise.circle", text: "R: replay the current line")
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
    
    private func featureBadge(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.yellow)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
        }
    }
    
    // MARK: - Auto Hide Controls
    private func wakeControls() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
        }
        hideTimer?.invalidate()
        if player.playbackState == .playing && !isExplanationOpen {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
                if player.playbackState == .playing && !isExplanationOpen {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                }
            }
        }
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
