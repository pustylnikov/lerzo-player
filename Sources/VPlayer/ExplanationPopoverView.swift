import SwiftUI
import AppKit

public struct ExplanationPopoverView: View {
    @ObservedObject var gemini = GeminiService.shared
    @ObservedObject var player = MPVPlayer.shared
    @Binding var isOpen: Bool
    @Binding var isSettingsOpen: Bool
    var focusedWord: String? = nil
    
    @State private var explanation: SubtitleExplanation? = nil
    @State private var errorText: String? = nil
    @State private var geminiError: GeminiError? = nil
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
                        Text("AI Dialogue Breakdown")
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
                } else if geminiError == .missingKey {
                    setupView
                } else if let err = geminiError {
                    errorView(err)
                } else if let err = errorText {
                    errorView(err)
                } else if let expl = explanation {
                    explanationContent(expl)
                    if let usage = gemini.lastUsage { usageLine(usage) }
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
                            Text("Replay line (R)")
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
                            Text("Continue (Space)")
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
            .frame(maxWidth: 760)
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
            
            Text("Gemini is analyzing the line's context and idioms...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    // MARK: - First run: no key yet
    private var setupView: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)
            
            Text("Set up AI explanations")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            
            Text("VPlayer explains idioms, slang and context with Google Gemini. It needs a free API key — getting one takes a minute, no card required.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(spacing: 10) {
                Link(destination: GeminiService.apiKeyPageURL) {
                    HStack(spacing: 5) {
                        Text("1. Get a free key")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(8)
                }
                
                primaryButton("2. Paste it in Settings") {
                    isOpen = false
                    isSettingsOpen = true
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    // MARK: - Error View
    private func errorView(_ error: GeminiError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            
            Text(error.errorDescription ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            
            if let hint = error.recoverySuggestion {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 10) {
                if error.pointsToSettings {
                    primaryButton("Open Settings") {
                        isOpen = false
                        isSettingsOpen = true
                    }
                }
                Button("Try again") { fetchExplanation() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    /// Plain-text failures that are not Gemini's fault (no subtitle to explain).
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.5))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
    
    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.yellow)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Token usage
    private func usageLine(_ usage: GeminiService.TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "number")
            Text("\(usage.total) tokens")
            if usage.thoughts > 0 { Text("· thinking \(usage.thoughts)") }
            Text("· session \(gemini.sessionUsage.total)")
            Spacer()
            Text(gemini.selectedModel)
        }
        .font(.system(size: 10))
        .foregroundColor(.white.opacity(0.45))
        .help("Prompt \(usage.prompt), answer \(usage.output), thinking \(usage.thoughts) tokens")
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.5))
            Text("No active subtitles right now.")
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
                    Text("Original:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .textCase(.uppercase)
                    Text("“\(expl.sentence)”")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
                
                // Translation
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contextual translation:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.yellow)
                        .textCase(.uppercase)
                    Text(expl.translation)
                        .font(.system(size: 18, weight: .medium))
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
                        Text("Idioms and set phrases:")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        
                        ForEach(expl.idioms) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("🎯 \(item.idiom)")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.yellow)
                                    Spacer()
                                }
                                Text("Meaning: \(item.actualMeaning)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                if !item.literalMeaning.isEmpty {
                                    Text("Literally: \(item.literalMeaning)")
                                        .font(.system(size: 13))
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
                        Text("Useful words from the line:")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        
                        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8, alignment: .leading) {
                            ForEach(expl.difficultWords) { word in
                                HStack(spacing: 4) {
                                    Text(word.word)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    if let pos = word.partOfSpeech, !pos.isEmpty {
                                        Text("(\(pos))")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    Text("— \(word.translation)")
                                        .font(.system(size: 14))
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
                        Text("💡 Scene context and tone:")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Text(note)
                            .font(.system(size: 14))
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
        // Use the window: a tall screen should show the whole breakdown without scrolling.
        .frame(maxHeight: max(360, (NSApp.keyWindow?.contentView?.bounds.height ?? 800) * 0.6))
    }
    
    private func fetchExplanation() {
        let sub = player.currentSubText.isEmpty ? (player.subtitleHistory.last ?? "") : player.currentSubText
        guard !sub.isEmpty else {
            errorText = String(localized: "There are no subtitles right now. Play the video and pause on a line you don't understand.")
            return
        }
        
        isFetching = true
        errorText = nil
        geminiError = nil
        
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
                    self.geminiError = GeminiError.from(transport: error)
                    self.isFetching = false
                }
            }
        }
    }
}
