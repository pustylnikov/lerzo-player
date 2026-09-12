import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var keyboardMonitor = KeyboardMonitor.shared
    
    @State private var showControls: Bool = true
    @State private var isSettingsOpen: Bool = false
    @State private var isExplanationOpen: Bool = false
    @State private var selectedWordToExplain: String? = nil
    @State private var hideTimer: Timer? = nil
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // LAYER 1: Native mpv video surface
            PlayerSurfaceView()
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
                    Text("Загрузка видео...")
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
            if showControls || player.playbackState == .paused || player.playbackState == .idle {
                ControlsOverlayView(
                    isSettingsOpen: $isSettingsOpen,
                    isExplanationOpen: $isExplanationOpen,
                    onOpenFile: openFileDialog
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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
        .frame(minWidth: 800, minHeight: 480)
        .background(player.playbackState == .idle && player.currentFileURL == nil ? Color(red: 0.08, green: 0.08, blue: 0.1) : Color.clear)
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
        }
        .onChange(of: isExplanationOpen) { _, isOpen in
            keyboardMonitor.isExplanationOpen = isOpen
            if !isOpen {
                selectedWordToExplain = nil
            }
        }
        .sheet(isPresented: $isSettingsOpen) {
            SettingsView(isOpen: $isSettingsOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
            isSettingsOpen = true
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
                Text("VPlayer — Плеер для изучения языка")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Перетащите сюда фильм (MKV, MP4) или нажмите кнопку ниже")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            HStack(spacing: 16) {
                Button(action: openFileDialog) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                        Text("Выбрать видео...")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.yellow)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
                let sampleURL = URL(fileURLWithPath: "/Users/yurii/Desktop/vplayer/test_media/sample_dialogue.mkv")
                if FileManager.default.fileExists(atPath: sampleURL.path) {
                    Button(action: {
                        player.loadFile(url: sampleURL)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                            Text("Открыть тестовый MKV с субтитрами")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Feature Highlights
            HStack(spacing: 24) {
                featureBadge(icon: "character.book.closed.fill", text: "TAB: Быстрый русский перевод")
                featureBadge(icon: "sparkles", text: "Gemini: Разбор идиом и сленга")
                featureBadge(icon: "arrow.counterclockwise.circle", text: "R: Повтор текущей реплики")
            }
            .padding(.top, 16)
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
    
    private func featureBadge(icon: String, text: String) -> some View {
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
        keyboardMonitor.onOpenSettingsRequested = {
            self.isSettingsOpen = true
        }
    }
    
    public func openFileDialog() {
        let panel = NSOpenPanel()
        panel.title = "Выберите видеофайл"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "mp4") ?? .movie,
            UTType(filenameExtension: "mov") ?? .movie,
            UTType(filenameExtension: "avi") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie,
            UTType(filenameExtension: "m4v") ?? .movie,
            .movie,
            .video
        ]
        
        if panel.runModal() == .OK, let url = panel.url {
            _ = url.startAccessingSecurityScopedResource()
            player.loadFile(url: url)
        }
    }
}
