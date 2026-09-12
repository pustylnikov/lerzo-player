import SwiftUI

public struct SubtitlesLayer: View {
    @ObservedObject var player = MPVPlayer.shared
    @Binding var showExplanation: Bool
    var onExplainWord: ((String) -> Void)?
    
    @State private var hoveredWord: String? = nil
    
    public init(showExplanation: Binding<Bool>, onExplainWord: ((String) -> Void)? = nil) {
        self._showExplanation = showExplanation
        self.onExplainWord = onExplainWord
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            Spacer()
            
            // Secondary (Russian) Subtitle Peek Badge
            if player.isPeekingRussian && !player.currentSecondarySubText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.yellow)
                    
                    Text(player.currentSecondarySubText)
                        .font(.system(size: max(16, CGFloat(player.subFontSize * 0.7)), weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.easeInOut(duration: 0.15), value: player.isPeekingRussian)
            }
            
            // Interactive English Subtitle Pill (active when paused or hovered)
            if !player.currentSubText.isEmpty && player.showSubtitles {
                let lines = player.currentSubText
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .center, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            let words = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            HStack(spacing: 5) {
                                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                                    subtitleWordView(for: word)
                                }
                            }
                        }
                    }
                    
                    // Quick Explain Button
                    Button(action: {
                        player.pause()
                        showExplanation = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                            Text("ИИ")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.yellow)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Объяснить эту фразу через Gemini AI (Cmd + G)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 3)
            }
        }
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private func subtitleWordView(for word: String) -> some View {
        let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
        Text(word)
            .font(.system(size: max(18, CGFloat(player.subFontSize * 0.65)), weight: .semibold, design: .rounded))
            .foregroundColor(hoveredWord == cleanWord ? .yellow : .white)
            .underline(hoveredWord == cleanWord, color: .yellow)
            .onHover { isHover in
                hoveredWord = isHover ? cleanWord : nil
            }
            .onTapGesture {
                onExplainWord?(cleanWord)
            }
    }
}

// Helper view for flowing words horizontally
struct WrappingHStack<Content: View>: View {
    let words: [String]
    let content: (String) -> Content
    
    init(words: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.words = words
        self.content = content
    }
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                content(word)
            }
        }
    }
}
