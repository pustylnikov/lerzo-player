import SwiftUI

public struct SettingsView: View {
    @ObservedObject var gemini = GeminiService.shared
    @ObservedObject var player = MPVPlayer.shared
    @Binding var isOpen: Bool
    
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
                    
                    // SECTION 2: SUBTITLES CUSTOMIZATION
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
                            
                            Slider(value: $player.subFontSize, in: 24...80, step: 2)
                                .accentColor(.yellow)
                        }
                        
                        // Live Preview Box
                        VStack(alignment: .center, spacing: 4) {
                            Text("Предпросмотр на экране:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text("Hey John, are you feeling under the weather?")
                                .font(.system(size: max(14, CGFloat(player.subFontSize * 0.5)), weight: .bold))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 2, x: 0, y: 1)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    
                    // SECTION 3: SHORTCUTS CHEATSHEET
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "keyboard")
                                .foregroundColor(.yellow)
                            Text("Горячие клавиши для изучения языка")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        shortcutRow(keys: "TAB", desc: "Зажать: мгновенно подглядеть русский перевод")
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
        .frame(width: 520, height: 600)
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
