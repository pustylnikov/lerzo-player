import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var gemini = GeminiService.shared
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var style = SubtitleStyle.shared
    @ObservedObject var languages = LanguagePreferences.shared
    @Binding var isOpen: Bool

    private let fontFamilies = SubtitleStyle.availableFontFamilies
    
    @State private var showApiKey: Bool = false
    @State private var keyCheck: KeyCheck = .idle
    @State private var modelsRefreshing = false

    private enum KeyCheck: Equatable {
        case idle, checking, valid, failed(GeminiError)
    }
    
    public init(isOpen: Binding<Bool>) {
        self._isOpen = isOpen
    }
    
    /// Tall enough to show everything without scrolling on a big display,
    /// but never taller than the screen the sheet is on (menu bar and Dock
    /// excluded), otherwise the header and the Done button get clipped.
    private var sheetHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - 48
        return min(1020, max(480, available))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.yellow)
                    Text("VPlayer Settings")
                        .font(.system(size: 18, weight: .bold))
                }
                
                Spacer()
                
                Button(action: { isOpen = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // SECTION 1: GEMINI AI
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                            Text("Gemini API Integration")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        Text("The key is used for contextual translation and for explaining slang and idioms from the movie.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Google AI Studio API Key:")
                                .font(.system(size: 12, weight: .medium))
                            
                            HStack {
                                if showApiKey {
                                    TextField("AIzaSy...", text: $gemini.apiKey)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("AIzaSy...", text: $gemini.apiKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                Button(action: { showApiKey.toggle() }) {
                                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        if !gemini.hasApiKey {
                            // First run: walk through getting a key.
                            VStack(alignment: .leading, spacing: 6) {
                                Label {
                                    Link("1. Open Google AI Studio and create a key (free, no card needed)",
                                         destination: GeminiService.apiKeyPageURL)
                                        .foregroundColor(.blue)
                                } icon: { Image(systemName: "1.circle").foregroundColor(.yellow) }
                                Label {
                                    Text("2. Paste it into the field above — VPlayer keeps it in your keychain.")
                                } icon: { Image(systemName: "2.circle").foregroundColor(.yellow) }
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }

                        if gemini.hasApiKey {
                            HStack {
                                Text("Model:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Picker("", selection: $gemini.selectedModel) {
                                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 260, alignment: .trailing)
                                Button(action: refreshModels) {
                                    if modelsRefreshing { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .disabled(modelsRefreshing)
                                .help("Reload the list of models available to this key")
                            }
                            Text("Flash models are the cheap, fast ones and have a free tier; Flash-Lite is cheaper still but explains idioms less well. Pro models are noticeably more expensive.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Toggle(isOn: $gemini.deepThinking) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Deep analysis (slower and more expensive)")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Lets the model think longer before answering. Rarely needed for a single line.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        HStack {
                            if gemini.hasApiKey {
                                Link("Google AI Studio ↗", destination: GeminiService.apiKeyPageURL)
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                            }

                            Spacer()

                            keyStatusView

                            Button("Check key") { checkKey() }
                                .controlSize(.small)
                                .disabled(!gemini.hasApiKey || keyCheck == .checking)
                        }
                        .onChange(of: gemini.apiKey) { _, _ in keyCheck = .idle }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    
                    // SECTION 2: LANGUAGES
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.yellow)
                            Text("Languages")
                                .font(.system(size: 14, weight: .bold))
                        }

                        Text("When a file opens, the player picks the audio and subtitles in the language you are learning, and subtitles in your native language for the TAB peek. The AI breakdown is in your native language too.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Interface language:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $languages.uiLanguage) {
                                Text("Same as system").tag(LanguagePreferences.system)
                                Divider()
                                ForEach(LanguagePreferences.uiLanguages, id: \.self) { code in
                                    Text(LanguagePreferences.nativeDisplayName(forUILanguage: code)).tag(code)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .trailing)
                        }

                        if languages.uiLanguageNeedsRelaunch {
                            HStack(spacing: 10) {
                                Text("The interface language changes after VPlayer is relaunched.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Spacer()
                                Button("Relaunch Now") { relaunchApp() }
                                    .controlSize(.small)
                            }
                        }

                        HStack {
                            Text("I'm learning:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $languages.learningLanguage) {
                                ForEach(LanguagePreferences.pickerLanguages, id: \.self) { code in
                                    Text(LanguagePreferences.displayName(for: code)).tag(code)
                                }
                                Divider()
                                Text("Don't select automatically").tag(LanguagePreferences.none)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .trailing)
                        }

                        HStack {
                            Text("Native language:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $languages.nativeLanguage) {
                                Text(systemLanguageLabel).tag(LanguagePreferences.system)
                                Divider()
                                ForEach(LanguagePreferences.pickerLanguages, id: \.self) { code in
                                    Text(LanguagePreferences.displayName(for: code)).tag(code)
                                }
                                Divider()
                                Text("Don't select automatically").tag(LanguagePreferences.none)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .trailing)
                        }

                        if languages.nativeLanguage != LanguagePreferences.none,
                           languages.resolvedNativeCode == nil,
                           languages.resolvedLearningCode != nil {
                            Text("Your native language is the same as the one you're learning — no translation subtitles will be selected.")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)

                    // SECTION 3: PLAYBACK BEHAVIOUR
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "play.circle")
                                .foregroundColor(.yellow)
                            Text("Playback Behavior")
                                .font(.system(size: 14, weight: .bold))
                        }

                        Toggle(isOn: $player.pauseWhilePeeking) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pause while peeking at the translation (TAB)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("While TAB is held the video pauses; it resumes when released.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(isOn: $player.boostDialogue) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Boost dialogue (B)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Evens out the volume and lifts speech above music and effects. Surround tracks are mixed to stereo with a louder centre channel.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(isOn: $player.hdrOutputEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Output HDR video in HDR")
                                    .font(.system(size: 12, weight: .medium))
                                Text(player.displaySupportsHDR
                                     ? "This display supports HDR. When off, HDR video is tone-mapped to SDR."
                                     : "This display does not support HDR — video is tone-mapped to SDR. The setting takes effect on an HDR display.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)

                    // SECTION 3b: PICTURE ADJUSTMENTS
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.yellow)
                            Text("Picture")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Button("Reset") { player.resetPictureAdjustments() }
                                .controlSize(.small)
                                .disabled(!player.hasPictureAdjustments)
                        }
                        Text("For a dark film on a dim screen or a bright room. Applies to every video until reset.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        pictureSlider("Brightness", value: $player.brightness)
                        pictureSlider("Contrast", value: $player.contrast)
                        pictureSlider("Saturation", value: $player.saturation)
                        pictureSlider("Gamma", value: $player.gamma)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)

                    // SECTION 4: SUBTITLES CUSTOMIZATION
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "textformat.size")
                                .foregroundColor(.yellow)
                            Text("Subtitle Appearance")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        // Font Size Slider
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Subtitle font size:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int(player.subFontSize)) pt")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            
                            Slider(value: $player.subFontSize, in: MPVPlayer.subFontSizeRange, step: 1)
                                .accentColor(.yellow)
                        }

                        // Translation Size
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Translation size (TAB):")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int((style.translationScale * 100).rounded()))% of primary")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.translationScale, in: SubtitleStyle.translationScaleRange, step: 0.05)
                                .accentColor(.yellow)
                        }

                        // Font Family
                        HStack {
                            Text("Font:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $style.fontFamily) {
                                Text("System").tag("")
                                Divider()
                                ForEach(fontFamilies, id: \.self) { family in
                                    Text(family).tag(family)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .trailing)
                        }

                        // Text Color
                        HStack {
                            Text("Text color:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            ColorPicker("", selection: $style.textColor, supportsOpacity: false)
                                .labelsHidden()
                        }

                        // Outline Width
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Outline width:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(style.outlineWidth == 0 ? String(localized: "none") : String(format: "%.1f pt", style.outlineWidth))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.outlineWidth, in: 0...6, step: 0.5)
                                .accentColor(.yellow)
                        }

                        // Outline Color
                        HStack {
                            Text("Outline color:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            ColorPicker("", selection: $style.outlineColor, supportsOpacity: false)
                                .labelsHidden()
                                .disabled(style.outlineWidth == 0)
                        }
                        
                        // Background Opacity
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Background opacity:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(style.backgroundOpacity == 0 ? String(localized: "no background") : String(localized: "\(Int(style.backgroundOpacity * 100))%"))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.backgroundOpacity, in: 0...1, step: 0.05)
                                .accentColor(.yellow)
                        }

                        // Bottom Inset
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Bottom inset:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int((style.bottomInset * 100).rounded()))% of height")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.bottomInset, in: SubtitleStyle.bottomInsetRange, step: 0.01)
                                .accentColor(.yellow)
                        }

                        // Live Preview Box
                        VStack(alignment: .center, spacing: 4) {
                            HStack {
                                Text("On-screen preview:")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Reset style") { style.reset() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                            
                            OutlinedText(
                                "Hey John, are you feeling under the weather?",
                                font: style.font(size: max(14, CGFloat(player.subFontSize * 0.75))),
                                color: style.textColor,
                                outlineColor: style.outlineColor,
                                outlineWidth: CGFloat(style.outlineWidth)
                            )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.black.opacity(style.backgroundOpacity))
                                .cornerRadius(8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(
                            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.45), Color(red: 0.45, green: 0.3, blue: 0.35)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(8)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    
                    // SECTION 5: SHORTCUTS CHEATSHEET
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "keyboard")
                                .foregroundColor(.yellow)
                            Text("Keyboard Shortcuts")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        ForEach(ShortcutsReference.groups) { group in
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.top, 4)
                            ForEach(group.entries) { entry in
                                ShortcutRowView(entry: entry)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                }
            }
            
            HStack {
                Spacer()
                Button("Done") {
                    isOpen = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 640, height: sheetHeight)
        // Otherwise the sheet focuses (and selects) the API key field on open.
        .background(InitialFocusSink())
        .onAppear { if gemini.hasApiKey && gemini.modelListIsStale { refreshModels() } }
    }
    
    @ViewBuilder
    private var keyStatusView: some View {
        switch keyCheck {
        case .idle:
            if gemini.hasApiKey {
                Label("Key is set", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
            }
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Label("Key works", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
        case .failed(let error):
            Label(error.errorDescription ?? "", systemImage: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
                .help(error.recoverySuggestion ?? "")
        }
    }

    /// The API's list when we have it, always including the current choice.
    private var modelChoices: [String] {
        var list = gemini.availableModels
        if !list.contains(gemini.selectedModel) { list.insert(gemini.selectedModel, at: 0) }
        return list
    }

    private func refreshModels() {
        modelsRefreshing = true
        Task {
            if let error = await gemini.refreshModels() {
                await MainActor.run { keyCheck = .failed(error) }
            }
            await MainActor.run { modelsRefreshing = false }
        }
    }

    private func checkKey() {
        keyCheck = .checking
        let key = gemini.apiKey
        Task {
            let result = await gemini.validateKey(key)
            await MainActor.run { keyCheck = result.map { .failed($0) } ?? .valid }
        }
    }

    /// Quits and reopens the app so the new `AppleLanguages` takes effect.
    private func relaunchApp() {
        // A helper waits for this process to exit, then opens the bundle
        // again — otherwise two instances would briefly run side by side.
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()

        isOpen = false
        DispatchQueue.main.async {
            NSApp.terminate(nil)
            // The sheet's modal session can swallow the quit; do not stay behind.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }

    private func pictureSlider(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            // No `step:` — AppKit draws a tick mark per step, which at 201
            // steps becomes a solid line under the slider. Values are rounded
            // to whole numbers when they reach mpv.
            Slider(value: value, in: MPVPlayer.pictureRange)
                .accentColor(.yellow)
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+d", Int(value.wrappedValue)))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(value.wrappedValue == 0 ? .secondary : .yellow)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var systemLanguageLabel: String {
        if let code = LanguagePreferences.systemLanguageCode {
            return String(localized: "Same as system (\(LanguagePreferences.displayName(for: code)))")
        }
        return String(localized: "Same as system")
    }

}

/// Invisible view that claims the sheet's initial first responder, so no
/// text field gets focused and selected just because it comes first.
private struct InitialFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }
    func makeNSView(context: Context) -> SinkView { SinkView(frame: .zero) }
    func updateNSView(_ nsView: SinkView, context: Context) {}
}
