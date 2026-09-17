import SwiftUI

public struct ControlsOverlayView: View {
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var cards = CardStore.shared
    @Environment(\.openWindow) private var openWindow
    @Binding var isSettingsOpen: Bool
    @Binding var isExplanationOpen: Bool
    @Binding var isShortcutsOpen: Bool
    var onOpenFile: () -> Void
    
    @ObservedObject var previewer = FramePreviewer.shared
    @State private var isHoveringSeeker: Bool = false
    /// Pointer position along the seek bar, in points from its left edge.
    @State private var seekHoverX: CGFloat? = nil
    /// The last position asked of the previewer: hover events repeat on
    /// every re-render of the bar, and each repeat would seek again.
    @State private var previewRequested: (url: URL, time: Double)? = nil
    @State private var seekDraggingValue: Double? = nil
    // The centre play badge flashes on pause and fades, so a study session
    // with pause-after-each-line does not park a black disc on the actor's
    // face while the line is read. It stays at the end of the file.

    private var canControlPlayback: Bool {
        player.currentFileURL != nil && player.playbackState != .idle && player.playbackState != .loading
    }
    
    public init(isSettingsOpen: Binding<Bool>,
                isExplanationOpen: Binding<Bool>,
                isShortcutsOpen: Binding<Bool>,
                onOpenFile: @escaping () -> Void) {
        self._isSettingsOpen = isSettingsOpen
        self._isExplanationOpen = isExplanationOpen
        self._isShortcutsOpen = isShortcutsOpen
        self.onOpenFile = onOpenFile
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // TOP HEADER BAR
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // Same for the top bar, for subtitles placed at the top.
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TopBarHeightKey.self, value: geo.size.height)
                })
            
            Spacer()
            
            // CENTER PLAY BIG ICON: only at the end of the file, where it says
            // "over, click to start again". A pause needs no badge — the frozen
            // picture and the bar's play button show it, and with pause-after-
            // each-line a badge would flash on the actor's face on every line.
            if player.playbackState == .finished {
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
                // Reports how much of the window's bottom the bar takes, so
                // the subtitle layer can stay clear of it (see SubtitleStyle).
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ControlsBarHeightKey.self, value: geo.size.height)
                })
                .disabled(!canControlPlayback)
                .opacity(canControlPlayback ? 1 : 0.42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: player.playbackState == .finished)
    }
    
    private var loopHelp: LocalizedStringKey {
        switch player.loopMode {
        case .off: return "Repeat the current line until turned off (L). ⇧L marks an A–B loop by hand"
        case .line: return "Repeating this line; W and E move the loop, any other seek ends it (L)"
        case .ab(_, nil): return "Loop start marked; press ⇧L again at the end. Click to loop the current line instead (L)"
        case .ab: return "A–B loop on; ⇧L clears it. Click to loop the current line instead (L)"
        }
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
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a video file (Cmd + O)")
            
            // Media Title: the one thing in the bar that gives way when the
            // window is narrow, so the buttons never wrap.
            if !player.mediaTitle.isEmpty {
                Text(player.mediaTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 350, alignment: .leading)
                    .layoutPriority(-1)
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

            Button(action: { openWindow(id: CardsWindow.windowID) }) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill")
                    Text("\(cards.newCount(for: player.currentFileURL))")
                        .monospacedDigit()
                        .frame(minWidth: 12)
                }
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.white)
                .frame(width: 48, height: 26)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Cards from this video (Cmd + E)")
            
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
                delayMenu(for: .subtitle)
                
                Divider()
                
                Text("Second track (translation):").font(.caption)
                Button(player.currentSecondarySubId == nil ? "✓ No second track" : "Turn off") {
                    player.setSecondarySubtitle(trackId: nil)
                }
                ForEach(player.subtitleTracks) { track in
                    Button(action: { player.setSecondarySubtitle(trackId: track.id) }) {
                        if player.currentSecondarySubId == track.id {
                            Text("✓ \(track.displayName)")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
                Divider()
                // Flat on purpose: nested menus do not open during playback.
                Button(player.translationMode == .peek ? "✓ Show while TAB is held" : "Show while TAB is held") {
                    player.translationMode = .peek
                    OSDController.shared.show(.translationMode)
                }
                Button(player.translationMode == .always ? "✓ Always show  (⇧TAB)" : "Always show  (⇧TAB)") {
                    player.translationMode = .always
                    OSDController.shared.show(.translationMode)
                }
                Divider()
                delayMenu(for: .secondarySubtitle)

                Divider()
                Button("Load subtitle file…  (⌘⇧O)") {
                    KeyboardMonitor.shared.onOpenSubtitleRequested?()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "captions.bubble.fill")
                    Text("Subtitles")
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .disabled(player.currentFileURL == nil)
            .help(player.currentFileURL == nil ? "Subtitles become available once a video is loaded" : "Choose a subtitle track or load a subtitle file")
            
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
                Divider()
                Button(player.boostDialogue ? "✓ Boost dialogue  (B)" : "Boost dialogue  (B)") {
                    player.boostDialogue.toggle(); OSDController.shared.show(.boostDialogue)
                }
                Divider()
                delayMenu(for: .audio)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Audio")
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .disabled(player.audioTracks.isEmpty)
            .help(player.audioTracks.isEmpty ? "Audio tracks become available once a video is loaded" : "Choose an audio track")
            
            // Video geometry: fit/fill, zoom, black bars
            Menu {
                Button(player.fillsWindow ? "Fit to window" : "✓ Fit to window") {
                    player.setFillsWindow(false); OSDController.shared.show(.fill)
                }
                Button(player.fillsWindow ? "✓ Fill window (crop edges)" : "Fill window (crop edges)") {
                    player.setFillsWindow(true); OSDController.shared.show(.fill)
                }
                Divider()
                Text("Zoom: \(Int((player.zoomScale * 100).rounded()))%").font(.caption)
                ForEach(MPVPlayer.zoomPresets, id: \.self) { preset in
                    Button(action: { player.setZoom(scale: preset); OSDController.shared.show(.zoom) }) {
                        Text(abs(player.zoomScale - preset) < 0.01 ? "✓ \(Int(preset * 100))%" : "\(Int(preset * 100))%")
                    }
                }
                Button("Zoom in  (=)") { player.adjustZoom(by: MPVPlayer.zoomStep); OSDController.shared.show(.zoom) }
                Button("Zoom out  (−)") { player.adjustZoom(by: -MPVPlayer.zoomStep); OSDController.shared.show(.zoom) }
                Button("Reset zoom and position  (0)") { player.resetZoomAndPan(); OSDController.shared.show(.zoom) }
                    .disabled(player.videoZoom == 0 && player.videoPanX == 0 && player.videoPanY == 0)
                Divider()
                Button("Remove black bars") {
                    player.removeBlackBars { OSDController.shared.show(.crop($0)) }
                }
                Button("Reset crop") { player.resetCrop() }
                    .disabled(player.videoCrop.isEmpty)
                Divider()
                Button(player.hasPictureAdjustments ? "✓ Brightness, contrast, gamma…" : "Brightness, contrast, gamma…") {
                    isSettingsOpen = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "aspectratio")
                    Text("Video")
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isVideoAdjusted ? .yellow : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(isVideoAdjusted ? 0.18 : 0.15))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .disabled(!canControlPlayback)
            .help("Zoom, move and crop the picture (= / −, Shift + arrows, 0)")
            
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
                .lineLimit(1)
                .fixedSize()
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
            
            // Keyboard cheat sheet
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { isShortcutsOpen.toggle() } }) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(isShortcutsOpen ? 0.3 : 0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Keyboard shortcuts (H)")

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
    private var isVideoAdjusted: Bool {
        player.videoZoom != 0 || player.videoPanX != 0 || player.videoPanY != 0 || player.fillsWindow || !player.videoCrop.isEmpty
    }

    /// Flat delay controls for one stream. Not a submenu: the controls bar
    /// re-renders on every time-pos tick while playing, and SwiftUI rebuilds
    /// nested NSMenus on each pass, which closes a submenu as soon as it opens.
    @ViewBuilder
    private func delayMenu(for stream: MPVPlayer.DelayStream) -> some View {
        Text("Delay: \(OSDView.delayLabel(player.delay(of: stream)))").font(.caption)
        switch stream {
        case .subtitle:
            Button("Earlier by 0.1 s  (Z)") { adjustDelay(stream, by: -MPVPlayer.delayStep) }
            Button("Later by 0.1 s  (X)") { adjustDelay(stream, by: MPVPlayer.delayStep) }
        case .audio:
            Button("Earlier by 0.1 s  (⇧Z)") { adjustDelay(stream, by: -MPVPlayer.delayStep) }
            Button("Later by 0.1 s  (⇧X)") { adjustDelay(stream, by: MPVPlayer.delayStep) }
        case .secondarySubtitle:
            Button("Earlier by 0.1 s") { adjustDelay(stream, by: -MPVPlayer.delayStep) }
            Button("Later by 0.1 s") { adjustDelay(stream, by: MPVPlayer.delayStep) }
        }
        Button("Reset delay") { adjustDelay(stream, by: nil) }
            .disabled(player.delay(of: stream) == 0)
    }

    private func adjustDelay(_ stream: MPVPlayer.DelayStream, by delta: Double?) {
        if let delta {
            player.adjustDelay(of: stream, by: delta)
        } else {
            player.resetDelay(of: stream)
        }
        OSDController.shared.show(.delay(stream))
    }

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
                Text(formatTime(displayTime, hours: player.duration >= 3600))
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
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if !isHoveringSeeker {
                                withAnimation(.easeInOut(duration: 0.15)) { isHoveringSeeker = true }
                            }
                            seekHoverX = point.x
                            requestPreview(atX: point.x, width: geo.size.width)
                        case .ended:
                            withAnimation(.easeInOut(duration: 0.15)) { isHoveringSeeker = false }
                            seekHoverX = nil
                            // A drag keeps the card while the pointer is off
                            // the bar; otherwise the next hover starts afresh.
                            if seekDraggingValue == nil { forgetPreview() }
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
                                requestPreview(atX: value.location.x, width: geo.size.width)
                            }
                            .onEnded { value in
                                if let target = seekDraggingValue {
                                    player.seek(to: target)
                                    seekDraggingValue = nil
                                }
                                if seekHoverX == nil { forgetPreview() }
                            }
                    )
                    // Frame preview above the pointer (or the thumb while
                    // scrubbing), kept within the bar's width.
                    .overlay(alignment: .bottom) {
                        if let x = seekDraggingValue.map({ CGFloat(player.duration > 0 ? $0 / player.duration : 0) * geo.size.width }) ?? seekHoverX,
                           player.duration > 0 {
                            let time = Self.previewTime(atX: x, width: geo.size.width, duration: player.duration)
                            let half = Self.previewWidth / 2
                            let centre = max(half, min(geo.size.width - half, x))
                            // The spacer stands on the bar, so the card
                            // ends 8 pt above it whatever its height.
                            VStack(spacing: 0) {
                                seekPreview(at: time)
                                Color.clear.frame(height: geo.size.height + 8)
                            }
                            .offset(x: centre - geo.size.width / 2)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 16)
                
                Text(formatTime(player.duration, hours: player.duration >= 3600))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 48, alignment: .trailing)
            }
            
            // Buttons Row: related controls sit 14 pt apart, groups 28 pt,
            // so the eye reads four clusters instead of one long strip.
            // Left to right: time (play, ±5 s), the line — navigation with
            // the replay hero, then its modes — and playback parameters.
            HStack(spacing: 28) {
                // Transport
                HStack(spacing: 14) {
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
                }

                // Line navigation
                HStack(spacing: 14) {
                    // Previous Subtitle Line
                    Button(action: { player.seekSubtitle(direction: -1) }) {
                        Image(systemName: "backward.end.alt.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the previous line (W)")

                    // Replay the current line — the hero of the bar.
                    // It stands out by form (the only labelled pill in the row),
                    // not by colour: a solid yellow fill would outshout the
                    // toggles, which are the ones carrying state.
                    Button(action: { player.seekSubtitle(direction: 0) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.yellow)
                            Text("Replay")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                        // Never let the layout squeeze the label away silently
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Replay the current line from the start (R)")

                    // Next Subtitle Line
                    Button(action: { player.seekSubtitle(direction: 1) }) {
                        Image(systemName: "forward.end.alt.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the next line (E)")
                }

                // Line modes
                // Toggles share one "on" treatment: the filled variant of the
                // same symbol in yellow.
                HStack(spacing: 14) {
                    // Repeat the current line
                    Button(action: { player.toggleLineLoop(); OSDController.shared.show(.loop) }) {
                        Image(systemName: player.loopMode == .off ? "repeat.circle" : "repeat.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(player.loopMode == .off ? .white.opacity(0.85) : .yellow)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(loopHelp)

                    // Pause after each line
                    Button(action: { player.autoPauseAfterLine.toggle(); OSDController.shared.show(.autoPause) }) {
                        HStack(spacing: 3) {
                            Image(systemName: player.autoPauseAfterLine ? "pause.circle.fill" : "pause.circle")
                                .font(.system(size: 13))
                                .frame(width: 18, height: 18)
                            if player.autoPauseTail > 0 {
                                Text("+" + OSDView.tailLabel(player.autoPauseTail))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                        }
                        .foregroundColor(player.autoPauseAfterLine ? .yellow : .white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help(player.autoPauseAfterLine
                          ? "Pausing at the end of every line; Space plays on to the next one (P). ⇧O / ⇧P pause earlier / later for subtitles that end mid-word"
                          : "Pause at the end of every line (P)")
                }

                // Audio and speed
                HStack(spacing: 14) {
                    // Volume Control
                    HStack(spacing: 6) {
                        // A toggle like loop and auto-pause: outline at rest,
                        // filled and yellow while the sound is off.
                        let muted = player.isMuted || player.volume == 0
                        Button(action: { player.toggleMute() }) {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                                .font(.system(size: 13))
                                .foregroundColor(muted ? .yellow : .white.opacity(0.85))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)

                        // Drawn by hand like the seek bar: the system slider
                        // turns grey whenever the window is not key.
                        VolumeSlider(volume: player.volume, muted: muted) { player.setVolume($0) }
                            .frame(width: 70, height: 16)
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
                            .background(isCustomSpeed ? Color.yellow.opacity(0.18) : Color.white.opacity(0.1))
                            .cornerRadius(5)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Playback speed ([ slower, ] faster, Backspace — 1×)")
                }
                Spacer()
                
                // Translation mode: a TAB hint that doubles as the pin toggle.
                // In a narrow window the wording goes first, the badge stays.
                let pinned = player.translationMode == .always
                Button(action: {
                    player.toggleTranslationMode()
                    OSDController.shared.show(.translationMode)
                }) {
                    ViewThatFits(in: .horizontal) {
                        translationPill(pinned: pinned, showsTitle: true)
                        translationPill(pinned: pinned, showsTitle: false)
                    }
                }
                .buttonStyle(.plain)
                .help(pinned
                      ? "The translation from the second subtitle track stays on screen. Click or press ⇧TAB to show it only while TAB is held"
                      : "Hold TAB to quickly see the translation from the second subtitle track. Click or press ⇧TAB to keep it on screen")
                
                // Fullscreen Toggle
                Button(action: {
                    player.toggleFullscreen()
                }) {
                    // isFullscreen is not published, but the bar re-renders on
                    // every time-pos update, so the glyph keeps up in practice.
                    Image(systemName: player.isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(player.isFullscreen ? "Exit full screen (F)" : "Full screen (F)")
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
    
    // MARK: - Seek preview

    private static let previewWidth = FramePreviewer.boxSize.width + 16

    /// The card shows whole seconds, so it asks for the frame at the start
    /// of the second under the pointer: a pixel is a fraction of a second on
    /// a short file, and the card would flip between frames within one label.
    private static func previewTime(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        floor(max(0, min(1, x / width)) * duration)
    }

    private func requestPreview(atX x: CGFloat, width: CGFloat) {
        guard let url = player.currentFileURL, player.duration > 0, width > 0 else { return }
        let time = Self.previewTime(atX: x, width: width, duration: player.duration)
        guard previewRequested?.url != url || previewRequested?.time != time else { return }
        previewRequested = (url, time)
        previewer.request(url: url, time: time)
    }

    private func forgetPreview() {
        previewRequested = nil
        previewer.clear()
    }

    /// The frame at `time` with the line spoken there laid over it the way
    /// the player shows subtitles, and the timestamp. The box keeps the
    /// source's proportions so an anamorphic or portrait picture is not
    /// stretched; before the first frame arrives it is a dark card of the
    /// player's aspect, so the card does not jump.
    private func seekPreview(at time: Double) -> some View {
        let preview = previewer.preview.flatMap { $0.url == player.currentFileURL ? $0 : nil }
        let aspect = preview?.aspect ?? player.videoAspect ?? 16 / 9
        let box = FramePreviewer.boxSize
        let width = min(box.width, box.height * aspect)
        let style = SubtitleStyle.shared
        return VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Color.black
                if let image = preview?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                }
                if let line = player.subtitleLine(at: time) {
                    OutlinedText(line,
                                 font: style.font(size: 9.5, weight: .semibold),
                                 color: style.textColor,
                                 outlineColor: style.outlineColor,
                                 outlineWidth: 1)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
            }
            .frame(width: width, height: width / aspect)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))

            Text(formatTime(time, hours: player.duration >= 3600))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(8)
        .frame(width: Self.previewWidth)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    /// Volume bar in the seek bar's style — a capsule with a yellow fill —
    /// so it keeps its colour in an inactive window and matches the row.
    private struct VolumeSlider: View {
        let volume: Double
        let muted: Bool
        let onChange: (Double) -> Void
        @State private var dragging: Double? = nil
        @State private var hovering = false

        var body: some View {
            GeometryReader { geo in
                let shown = dragging ?? volume
                let fraction = max(0, min(1, shown / 100))
                let x = fraction * geo.size.width
                let trackHeight: CGFloat = hovering ? 5 : 3
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(muted ? Color.white.opacity(0.45) : Color.yellow)
                        .frame(width: x, height: trackHeight)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, min(x - 5, geo.size.width - 10)))
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.15)) { hovering = hover }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let v = Double(max(0, min(1, value.location.x / geo.size.width))) * 100
                            dragging = v
                            onChange(v)
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
        }
    }

    private func translationPill(pinned: Bool, showsTitle: Bool) -> some View {
        HStack(spacing: 5) {
            // Without the wording, an eye says "peek"; it fills when pinned,
            // like the other toggles.
            if !showsTitle {
                Image(systemName: pinned ? "eye.fill" : "eye")
                    .font(.system(size: 11))
            }
            Text(pinned ? "⇧TAB" : "TAB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.2))
                .cornerRadius(4)
            if showsTitle {
                Text(pinned ? "Translation on" : "Peek translation")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundColor(pinned ? .yellow : .white.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(pinned ? Color.yellow.opacity(0.18) : Color.white.opacity(0.1))
        .cornerRadius(6)
        .fixedSize()
    }

    // Elapsed time and duration share one format, chosen by the duration,
    // so the elapsed label does not change shape when playback passes an hour.
    private func formatTime(_ seconds: Double, hours: Bool) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return hours ? "0:00:00" : "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if hours {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

/// Height of the bottom controls bar including its margin to the window edge.
struct ControlsBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the top header bar including its margin to the window edge.
struct TopBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// Darkening behind the top bar, shown together with the controls so its
/// buttons and the file name stay readable on bright video. Fades out over
/// the top third; the bottom bar has its own opaque background and the
/// subtitles live there, so nothing is tinted below.
struct ControlsBackdropView: View {
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.black.opacity(0.6),
                Color.clear,
                Color.clear,
                Color.clear
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        // The window has a hidden title bar; without this the gradient
        // would start below its safe-area inset, leaving an untinted strip.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
