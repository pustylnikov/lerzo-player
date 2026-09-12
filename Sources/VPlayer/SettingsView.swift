import SwiftUI

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
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.yellow)
                    Text("Настройки VPlayer")
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
                            Text("Интеграция с Gemini API")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        Text("Ключ используется для контекстного перевода и разбора сленга/идиом из фильма.")
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
                            Link("Получить бесплатный API ключ в Google AI Studio ↗",
                                 destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            
                            Spacer()
                            
                            if gemini.hasApiKey {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Ключ активен")
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
                            Text("Языки")
                                .font(.system(size: 14, weight: .bold))
                        }

                        Text("При открытии файла плеер сам выберет аудио и субтитры на изучаемом языке, а для подглядывания по TAB — субтитры на родном. ИИ-разбор тоже будет на родном языке.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Изучаю:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $languages.learningLanguage) {
                                ForEach(LanguagePreferences.pickerLanguages, id: \.self) { code in
                                    Text(LanguagePreferences.displayName(for: code)).tag(code)
                                }
                                Divider()
                                Text("Не выбирать автоматически").tag(LanguagePreferences.none)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }

                        HStack {
                            Text("Родной язык:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $languages.nativeLanguage) {
                                Text(systemLanguageLabel).tag(LanguagePreferences.system)
                                Divider()
                                ForEach(LanguagePreferences.pickerLanguages, id: \.self) { code in
                                    Text(LanguagePreferences.displayName(for: code)).tag(code)
                                }
                                Divider()
                                Text("Не выбирать автоматически").tag(LanguagePreferences.none)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }

                        if languages.nativeLanguage != LanguagePreferences.none,
                           languages.resolvedNativeCode == nil,
                           languages.resolvedLearningCode != nil {
                            Text("Родной язык совпадает с изучаемым — субтитры перевода выбираться не будут.")
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
                            Text("Поведение при просмотре")
                                .font(.system(size: 14, weight: .bold))
                        }

                        Toggle(isOn: $player.pauseWhilePeeking) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Пауза при подглядывании перевода (TAB)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Пока TAB зажат, видео стоит; после отпускания продолжает играть.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(isOn: $player.hdrOutputEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Выводить HDR-видео в HDR")
                                    .font(.system(size: 12, weight: .medium))
                                Text(player.displaySupportsHDR
                                     ? "Текущий дисплей поддерживает HDR. Если выключить, HDR-видео будет преобразовано в SDR."
                                     : "Текущий дисплей не поддерживает HDR — видео преобразуется в SDR. Настройка применится на HDR-дисплее.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
                            Text("Отображение субтитров")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        // Font Size Slider
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Размер шрифта субтитров:")
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
                                Text("Размер перевода (TAB):")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int((style.translationScale * 100).rounded())) % от основных")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.translationScale, in: SubtitleStyle.translationScaleRange, step: 0.05)
                                .accentColor(.yellow)
                        }

                        // Font Family
                        HStack {
                            Text("Шрифт:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $style.fontFamily) {
                                Text("Системный").tag("")
                                Divider()
                                ForEach(fontFamilies, id: \.self) { family in
                                    Text(family).tag(family)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }

                        // Text Color
                        HStack {
                            Text("Цвет текста:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            ColorPicker("", selection: $style.textColor, supportsOpacity: false)
                                .labelsHidden()
                        }

                        // Outline Width
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Толщина обводки:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(style.outlineWidth == 0 ? "нет" : String(format: "%.1f pt", style.outlineWidth))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.outlineWidth, in: 0...6, step: 0.5)
                                .accentColor(.yellow)
                        }

                        // Outline Color
                        HStack {
                            Text("Цвет обводки:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            ColorPicker("", selection: $style.outlineColor, supportsOpacity: false)
                                .labelsHidden()
                                .disabled(style.outlineWidth == 0)
                        }
                        
                        // Background Opacity
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Прозрачность подложки:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(style.backgroundOpacity == 0 ? "без подложки" : "\(Int(style.backgroundOpacity * 100)) %")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.backgroundOpacity, in: 0...1, step: 0.05)
                                .accentColor(.yellow)
                        }

                        // Bottom Inset
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Отступ снизу:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int((style.bottomInset * 100).rounded())) % высоты")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                            Slider(value: $style.bottomInset, in: SubtitleStyle.bottomInsetRange, step: 0.01)
                                .accentColor(.yellow)
                        }

                        // Live Preview Box
                        VStack(alignment: .center, spacing: 4) {
                            HStack {
                                Text("Предпросмотр на экране:")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Сбросить стиль") { style.reset() }
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
                            Text("Горячие клавиши для изучения языка")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        shortcutRow(keys: "TAB", desc: "Зажать: мгновенно подглядеть перевод (вторая дорожка субтитров)")
                        shortcutRow(keys: "R", desc: "Повторить текущую реплику сначала (sub-seek 0)")
                        shortcutRow(keys: "E", desc: "Перейти к следующей реплике диалога")
                        shortcutRow(keys: "⌘ + G", desc: "ИИ разбор текущей фразы через Gemini")
                        shortcutRow(keys: "Пробел", desc: "Пауза / Воспроизведение")
                        shortcutRow(keys: "←  /  →", desc: "Перемотка на 5 секунд назад / вперед")
                        shortcutRow(keys: "F", desc: "Полноэкранный режим")
                        shortcutRow(keys: "⌘ + O", desc: "Открыть видео или внешний файл субтитров")
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                }
            }
            
            HStack {
                Spacer()
                Button("Готово") {
                    isOpen = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 520, height: 980)
    }
    
    private var systemLanguageLabel: String {
        if let code = LanguagePreferences.systemLanguageCode {
            return "Как в системе (\(LanguagePreferences.displayName(for: code)))"
        }
        return "Как в системе"
    }

    private func shortcutRow(keys: String, desc: String) -> some View {
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
