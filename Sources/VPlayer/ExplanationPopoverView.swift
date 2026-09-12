import SwiftUI

public struct ExplanationPopoverView: View {
    @ObservedObject var gemini = GeminiService.shared
    @ObservedObject var player = MPVPlayer.shared
    @Binding var isOpen: Bool
    @Binding var isSettingsOpen: Bool
    var focusedWord: String? = nil
    
    @State private var explanation: SubtitleExplanation? = nil
    @State private var errorText: String? = nil
    @State private var isFetching: Bool = false
    
    public init(isOpen: Binding<Bool>, isSettingsOpen: Binding<Bool>, focusedWord: String? = nil) {
        self._isOpen = isOpen
        self._isSettingsOpen = isSettingsOpen
        self.focusedWord = focusedWord
    }
    
    public var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture {
                    isOpen = false
                }
            
            // Content Card
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.yellow)
                        Text("ИИ Разбор диалога")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    if let word = focusedWord, !word.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "character.cursor.ibeam")
                                .font(.system(size: 11))
                            Text(word)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.18))
                        .cornerRadius(6)
                    }
                    
                    Spacer()
                    
                    Button(action: { isOpen = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                
                Divider().background(Color.white.opacity(0.15))
                
                // Body content based on state
                if isFetching {
                    loadingView
                } else if let err = errorText {
                    errorView(err)
                } else if let expl = explanation {
                    explanationContent(expl)
                } else {
                    emptyStateView
                }
                
                Divider().background(Color.white.opacity(0.15))
                
                // Footer Buttons
                HStack {
                    Button(action: {
                        player.seekSubtitle(direction: 0)
                        isOpen = false
                        player.play()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise.circle")
                            Text("Повторить фразу (R)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: {
                        isOpen = false
                        player.play()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("Продолжить (Пробел)")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.yellow)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(maxWidth: 620)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.7), radius: 24, x: 0, y: 10)
        }
        .onAppear {
            fetchExplanation()
        }
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .colorInvert()
            
            Text("Gemini анализирует контекст реплики и идиомы...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    // MARK: - Error View
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            
            if !gemini.hasApiKey {
                Button(action: {
                    isOpen = false
                    isSettingsOpen = true
                }) {
                    Text("Ввести Gemini API ключ в Настройках")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else {
                Button("Повторить запрос") {
                    fetchExplanation()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.5))
            Text("В данный момент нет активных субтитров.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    // MARK: - Explanation Content
    private func explanationContent(_ expl: SubtitleExplanation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Original sentence
                VStack(alignment: .leading, spacing: 4) {
                    Text("Оригинал:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .textCase(.uppercase)
                    Text("“\(expl.sentence)”")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
                
                // Translation
                VStack(alignment: .leading, spacing: 4) {
                    Text("Контекстный перевод:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.yellow)
                        .textCase(.uppercase)
                    Text(expl.translation)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(10)
                
                // Idioms & Slang (if any)
                if !expl.idioms.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Идиомы и устойчивые выражения:")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        
                        ForEach(expl.idioms) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("🎯 \(item.idiom)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.yellow)
                                    Spacer()
                                }
                                Text("Значение: \(item.actualMeaning)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                if !item.literalMeaning.isEmpty {
                                    Text("Дословно: \(item.literalMeaning)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                    }
                }
                
                // Difficult Words
                if !expl.difficultWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Полезные слова из фразы:")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        
                        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8, alignment: .leading) {
                            ForEach(expl.difficultWords) { word in
                                HStack(spacing: 4) {
                                    Text(word.word)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                    if let pos = word.partOfSpeech, !pos.isEmpty {
                                        Text("(\(pos))")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    Text("— \(word.translation)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                
                // Context Note
                if let note = expl.contextNote, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 Контекст и интонация сцены:")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            .lineSpacing(3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                }
            }
        }
        .frame(maxHeight: 360)
    }
    
    private func fetchExplanation() {
        let sub = player.currentSubText.isEmpty ? (player.subtitleHistory.last ?? "") : player.currentSubText
        guard !sub.isEmpty else {
            errorText = "Субтитры сейчас пусты. Включите видео и нажмите паузу на непонятной реплике."
            return
        }
        
        isFetching = true
        errorText = nil
        
        Task {
            do {
                let res = try await gemini.explain(
                    subText: sub,
                    contextHistory: player.subtitleHistory.dropLast(),
                    translationPeekText: player.currentSecondarySubText,
                    focusedWord: focusedWord
                )
                await MainActor.run {
                    self.explanation = res
                    self.isFetching = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.isFetching = false
                }
            }
        }
    }
}
