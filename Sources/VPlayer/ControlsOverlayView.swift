import SwiftUI

public struct ControlsOverlayView: View {
    @ObservedObject var player = MPVPlayer.shared
    @Binding var isSettingsOpen: Bool
    @Binding var isExplanationOpen: Bool
    var onOpenFile: () -> Void
    
    @State private var isHoveringSeeker: Bool = false
    @State private var seekDraggingValue: Double? = nil

    private var canControlPlayback: Bool {
        player.currentFileURL != nil && player.playbackState != .idle && player.playbackState != .loading
    }
    
    public init(isSettingsOpen: Binding<Bool>,
                isExplanationOpen: Binding<Bool>,
                onOpenFile: @escaping () -> Void) {
        self._isSettingsOpen = isSettingsOpen
        self._isExplanationOpen = isExplanationOpen
        self.onOpenFile = onOpenFile
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // TOP HEADER BAR
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
            
            Spacer()
            
            // CENTER PLAY BIG ICON (when paused or finished)
            if player.playbackState == .paused || player.playbackState == .finished {
                Button(action: { player.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 72, height: 72)
                        Image(systemName: "play.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .offset(x: 3)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            
            Spacer()
            
            // BOTTOM CONTROLS BAR
            bottomBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .disabled(!canControlPlayback)
                .opacity(canControlPlayback ? 1 : 0.42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Subtle gradient darkening at edges for contrast
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.6),
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(0.7)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 12) {
            // Open File Button
            Button(action: onOpenFile) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Open")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a video file (Cmd + O)")
            
            // Media Title
            if !player.mediaTitle.isEmpty {
                Text(player.mediaTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 350, alignment: .leading)
            }

            if player.isHDRContent {
                let passthrough = player.hdrOutputEnabled && player.displaySupportsHDR
                Text("HDR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(passthrough ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(passthrough ? Color.yellow : Color.white.opacity(0.15))
                    )
                    .help(passthrough ? "HDR video is output in HDR" : "HDR video is tone-mapped to SDR (the display does not support HDR, or HDR output is disabled in Settings)")
            }
            
            Spacer()
            
            // Subtitle Selection Menu
            Menu {
                Text("Primary track (original language):").font(.caption)
                Button(player.currentPrimarySubId == nil ? "✓ No subtitles" : "Turn off") {
                    player.setPrimarySubtitle(trackId: nil)
                }
                ForEach(player.subtitleTracks) { track in
                    Button(action: { player.setPrimarySubtitle(trackId: track.id) }) {
                        if player.currentPrimarySubId == track.id {
                            Text("✓ \(track.displayName)")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
                
                Divider()
                
                Text("Second track (translation to peek at with TAB):").font(.caption)
                Button(player.currentSecondarySubId == nil ? "✓ No second track" : "Turn off") {
                    player.setSecondarySubtitle(trackId: nil)
                }
                ForEach(player.subtitleTracks) { track in
                    Button(action: { player.setSecondarySubtitle(trackId: track.id) }) {
                        if player.currentSecondarySubId == track.id {
                            Text("✓ (Peek) \(track.displayName)")
                        } else {
                            Text("(Peek) \(track.displayName)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "captions.bubble.fill")
                    Text("Subtitles")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .disabled(player.subtitleTracks.isEmpty)
            .help(player.subtitleTracks.isEmpty ? "Subtitles become available once a video with subtitle tracks is loaded" : "Choose a subtitle track")
            
            // Audio Track Selection Menu
            Menu {
                ForEach(player.audioTracks) { track in
                    Button(action: { player.setAudioTrack(trackId: track.id) }) {
                        if player.currentAudioTrackId == track.id {
                            Text("✓ \(track.displayName)")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Audio")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .disabled(player.audioTracks.isEmpty)
            .help(player.audioTracks.isEmpty ? "Audio tracks become available once a video is loaded" : "Choose an audio track")
            
            // Gemini AI Explain Action Button
            Button(action: {
                player.pause()
                isExplanationOpen = true
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.yellow)
                    Text("Explain line")
                        .foregroundColor(.white)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.2, green: 0.2, blue: 0.25).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                )
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: .command)
            .help("Explain the current line and its idioms with Gemini (Cmd + G)")
            .disabled(!canControlPlayback)
            
            // Settings Button
            Button(action: { isSettingsOpen.toggle() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Subtitle and Gemini API settings (Cmd + ,)")
        }
    }
    
    // MARK: - Bottom Bar
    private var isCustomSpeed: Bool { abs(player.playbackSpeed - 1) > 0.01 }

    /// "1×", "0.75×", "1.5×" — trailing zeros dropped.
    private static func speedLabel(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Seek bar + Time labels
            HStack(spacing: 10) {
                let displayTime = seekDraggingValue ?? player.currentTime
                Text(formatTime(displayTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 48, alignment: .leading)
                
                // Timeline Slider
                GeometryReader { geo in
                    let progress = player.duration > 0 ? (displayTime / player.duration) : 0
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(height: isHoveringSeeker ? 6 : 4)
                        
                        // Filled progress
                        Capsule()
                            .fill(Color.yellow)
                            .frame(width: max(0, CGFloat(progress) * geo.size.width), height: isHoveringSeeker ? 6 : 4)
                        
                        // Thumb
                        if isHoveringSeeker {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                                .offset(x: max(0, CGFloat(progress) * geo.size.width - 6))
                        }
                    }
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .onHover { isHover in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringSeeker = isHover
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // Scrubbing pauses playback; the user presses
                                // play to continue from the new position.
                                if seekDraggingValue == nil {
                                    player.pause()
                                }
                                let fraction = max(0, min(1, value.location.x / geo.size.width))
                                seekDraggingValue = fraction * player.duration
                            }
                            .onEnded { value in
                                if let target = seekDraggingValue {
                                    player.seek(to: target)
                                    seekDraggingValue = nil
                                }
                            }
                    )
                }
                .frame(height: 16)
                
                Text(formatTime(player.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 48, alignment: .trailing)
            }
            
            // Buttons Row
            HStack(spacing: 16) {
                // Play / Pause
                // Fixed frame: play.fill and pause.fill have different widths,
                // so without it the whole row shifts on every toggle.
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                
                // Replay Current Subtitle Line (Language Learning Feature!)
                Button(action: { player.seekSubtitle(direction: 0) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                        Text("Replay")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.yellow)
                }
                .buttonStyle(.plain)
                .help("Replay the current line from the start (R)")
                
                // Skip -5s
                Button(action: { player.seekRelative(seconds: -5) }) {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Back 5 seconds (Left Arrow)")
                
                // Skip +5s
                Button(action: { player.seekRelative(seconds: 5) }) {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Forward 5 seconds (Right Arrow)")
                
                // Next Subtitle Line
                Button(action: { player.seekSubtitle(direction: 1) }) {
                    Image(systemName: "forward.end.alt.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Jump to the next line (E)")
                
                // Volume Control
                HStack(spacing: 6) {
                    Button(action: { player.toggleMute() }) {
                        Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: Binding(
                        get: { player.volume },
                        set: { player.setVolume($0) }
                    ), in: 0...100)
                    .frame(width: 70)
                    .accentColor(.yellow)
                }

                // Playback Speed
                Menu {
                    ForEach(MPVPlayer.speedPresets, id: \.self) { preset in
                        Button(action: { player.setSpeed(preset) }) {
                            if abs(player.playbackSpeed - preset) < 0.01 {
                                Label(Self.speedLabel(preset), systemImage: "checkmark")
                            } else {
                                Text(Self.speedLabel(preset))
                            }
                        }
                    }
                } label: {
                    Text(Self.speedLabel(player.playbackSpeed))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isCustomSpeed ? .yellow : .white.opacity(0.85))
                        .frame(width: 44, height: 20)
                        .background(Color.white.opacity(isCustomSpeed ? 0.18 : 0.1))
                        .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Playback speed ([ slower, ] faster, Backspace — 1×)")
                
                Spacer()
                
                // Peek Hint Pill
                HStack(spacing: 5) {
                    Text("TAB")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(4)
                    Text("Peek translation")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)
                .help("Hold TAB to quickly see the translation from the second subtitle track")
                
                // Fullscreen Toggle
                Button(action: {
                    player.toggleFullscreen()
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Full screen (F)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
