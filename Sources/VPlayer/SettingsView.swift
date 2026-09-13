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
                        
                        HStack {
                            Link("Get a free API key in Google AI Studio ↗",
                                 destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            
                            Spacer()
                            
                            if gemini.hasApiKey {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Key is set")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.green)
                                }
                            }
                        }
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
                        
                        shortcutRow(keys: "TAB", desc: "Hold: instantly peek at the translation (second subtitle track)")
                        shortcutRow(keys: "R", desc: "Replay the current line from the start")
                        shortcutRow(keys: "E", desc: "Jump to the next line of dialogue")
                        shortcutRow(keys: "⌘ + G", desc: "AI breakdown of the current line with Gemini")
                        shortcutRow(keys: "Space", desc: "Pause / Play")
                        shortcutRow(keys: "←  /  →", desc: "Seek 5 seconds back / forward")
                        shortcutRow(keys: "↑  /  ↓", desc: "Volume +5% / −5%")
                        shortcutRow(keys: "M", desc: "Mute / unmute")
                        shortcutRow(keys: "[  /  ]", desc: "Speed: slower / faster by 0.1×")
                        shortcutRow(keys: "⌫", desc: "Reset speed to 1×")
                        shortcutRow(keys: "F", desc: "Full screen")
                        shortcutRow(keys: "⌘ + O", desc: "Open a video or an external subtitle file")
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
        .frame(width: 520, height: sheetHeight)
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

    private var systemLanguageLabel: String {
        if let code = LanguagePreferences.systemLanguageCode {
            return String(localized: "Same as system (\(LanguagePreferences.displayName(for: code)))")
        }
        return String(localized: "Same as system")
    }

    private func shortcutRow(keys: LocalizedStringKey, desc: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.15))
                .cornerRadius(5)
                .frame(minWidth: 65, alignment: .center)
            
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
            
            Spacer()
        }
    }
}
