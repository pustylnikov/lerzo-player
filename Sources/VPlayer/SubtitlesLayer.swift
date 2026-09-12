import SwiftUI

public struct SubtitlesLayer: View {
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var style = SubtitleStyle.shared
    @Binding var showExplanation: Bool
    var onExplainWord: ((String) -> Void)?
    
    @State private var hoveredWord: String? = nil
    @State private var isHoveringPill: Bool = false
    
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
                    OutlinedText(
                        player.currentSecondarySubText,
                        font: style.font(size: max(16, CGFloat(player.subFontSize * 0.7)), weight: .medium),
                        color: style.textColor,
                        outlineColor: style.outlineColor,
                        outlineWidth: CGFloat(style.outlineWidth)
                    )
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.85 * boxOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.yellow.opacity(0.4 * boxOpacity), lineWidth: 1)
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
                
                VStack(alignment: .center, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let words = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        WrappingHStack(words: words) { word in
                            subtitleWordView(for: word)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(boxOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15 * boxOpacity), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.5 * boxOpacity), radius: 6, x: 0, y: 3)
                // Quick Explain badge: floats over the pill's top-right corner
                // and only appears on hover, so it neither shifts the centred
                // text nor sits on screen the whole time.
                .overlay(alignment: .topTrailing) {
                    explainBadge
                        .offset(x: 10, y: -10)
                        .opacity(isHoveringPill ? 1 : 0)
                        .allowsHitTesting(isHoveringPill)
                }
                // Extra room so the hover region also covers the floating badge.
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .onHover { isHover in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringPill = isHover
                    }
                }
            }
        }
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity)
    }
    
    private var boxOpacity: Double { style.backgroundOpacity }

    private var explainBadge: some View {
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
            .background(Capsule().fill(Color.yellow))
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("Объяснить эту фразу через Gemini AI (Cmd + G)")
    }

    @ViewBuilder
    private func subtitleWordView(for word: String) -> some View {
        let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
        let isHovered = hoveredWord == cleanWord
        OutlinedText(
            word,
            font: style.font(size: max(18, CGFloat(player.subFontSize * 0.65))),
            color: isHovered ? .yellow : style.textColor,
            outlineColor: style.outlineColor,
            outlineWidth: CGFloat(style.outlineWidth)
        )
            .lineLimit(1)
            .fixedSize()
            .overlay(alignment: .bottom) {
                if isHovered {
                    Rectangle().fill(Color.yellow).frame(height: 2)
                }
            }
            .onHover { isHover in
                hoveredWord = isHover ? cleanWord : nil
            }
            .onTapGesture {
                onExplainWord?(cleanWord)
            }
    }
}

// Flows words left to right and wraps whole words onto new rows when the
// available width runs out. A plain HStack would instead squeeze each Text
// and break words mid-way.
struct WrappingHStack<Content: View>: View {
    let words: [String]
    let content: (String) -> Content
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 2

    init(words: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.words = words
        self.content = content
    }

    var body: some View {
        FlowLayout(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                content(word)
            }
        }
    }
}

/// Wraps whole subviews onto new rows when the available width runs out.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 2
    var alignment: HorizontalAlignment = .center

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, in maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = current.items.isEmpty ? 0 : horizontalSpacing
            if !current.items.isEmpty && current.width + extra + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            let spacing = current.items.isEmpty ? 0 : horizontalSpacing
            current.items.append((index, size))
            current.width += spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, in: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            let slack = bounds.width - row.width
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.minX + slack
            default: x = bounds.minX + slack / 2
            }
            for item in row.items {
                let origin = CGPoint(x: x, y: y + (row.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }
}
