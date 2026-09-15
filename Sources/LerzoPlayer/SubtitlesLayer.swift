import SwiftUI

public struct SubtitlesLayer: View {
    @ObservedObject var player = MPVPlayer.shared
    @ObservedObject var style = SubtitleStyle.shared
    @ObservedObject var lookup = DictionaryLookup.shared
    @Binding var showExplanation: Bool
    /// Height of the playback controls bar (with its bottom margin), measured
    /// by `ControlsOverlayView`; 0 until it has been shown once.
    var controlsBarHeight: CGFloat
    /// Height of the top header bar (with its top margin), likewise.
    var topBarHeight: CGFloat
    var controlsShown: Bool
    var onExplainWord: ((String) -> Void)?
    
    @State private var hoveredWord: String? = nil
    /// Recreates the word hover regions after a full-screen overlay or the
    /// dictionary catcher disappears. AppKit does not always send a fresh
    /// mouse-enter event to the SwiftUI views underneath until another player
    /// state change occurs.
    @State private var wordHoverRevision = 0
    /// Height of the video area, which the font scale is applied to.
    @State private var areaHeight: CGFloat = MPVPlayer.subFontReferenceHeight
    @State private var isHoveringPill: Bool = false
    /// Heights of the lines placed at each edge, to see whether they fit in
    /// the letterbox band there.
    @State private var topBlockHeight: CGFloat = 0
    @State private var bottomBlockHeight: CGFloat = 0
    
    public init(showExplanation: Binding<Bool>,
                controlsBarHeight: CGFloat = 0,
                topBarHeight: CGFloat = 0,
                controlsShown: Bool = false,
                onExplainWord: ((String) -> Void)? = nil) {
        self._showExplanation = showExplanation
        self.controlsBarHeight = controlsBarHeight
        self.topBarHeight = topBarHeight
        self.controlsShown = controlsShown
        self.onExplainWord = onExplainWord
    }
    
    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // The original always sits next to its edge and the translation
                // on the inner side (see `SubtitleStyle.translationPosition`),
                // so the stacks read edge-inwards: bottom-up at the bottom,
                // top-down at the top.
                VStack(spacing: 0) {
                    blocks(at: .top, availableWidth: geo.size.width)
                        .background(GeometryReader { block in
                            Color.clear
                                .onAppear { topBlockHeight = block.size.height }
                                .onChange(of: block.size.height) { _, height in topBlockHeight = height }
                        })
                    Spacer(minLength: 0)
                }
                .padding(.top, bandInset(band: player.videoTopMargin, block: topBlockHeight,
                                         bar: topBarHeight, height: geo.size.height))
                // Only the "lift while visible" mode ever changes the inset at
                // runtime; window resizes must not animate.
                .animation(.easeInOut(duration: 0.2), value: controlsShown)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    blocks(at: .bottom, availableWidth: geo.size.width)
                        .background(GeometryReader { block in
                            Color.clear
                                .onAppear { bottomBlockHeight = block.size.height }
                                .onChange(of: block.size.height) { _, height in bottomBlockHeight = height }
                        })
                }
                .padding(.bottom, bandInset(band: player.videoBottomMargin, block: bottomBlockHeight,
                                            bar: controlsBarHeight, height: geo.size.height))
                .animation(.easeInOut(duration: 0.2), value: controlsShown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { areaHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, height in areaHeight = height }
        }
        // The dictionary card belongs to one line: it goes when the line
        // does, or when playback resumes (Space, R, W, E...).
        .onChange(of: player.subTextOnScreen) { _, _ in lookup.close() }
        .onChange(of: player.playbackState) { _, state in
            if state == .playing { lookup.close() }
        }
        .onChange(of: lookup.word) { previous, current in
            if previous != nil && current == nil { resetWordHoverRegions() }
        }
        .onChange(of: showExplanation) { wasOpen, isOpen in
            if wasOpen && !isOpen { resetWordHoverRegions() }
        }
    }

    /// The user's inset, pushed clear of the controls bar at that edge when
    /// it would overlap: permanently or only while the bar is on screen, per
    /// `SubtitleStyle`.
    private func inset(for height: CGFloat, clearing barHeight: CGFloat) -> CGFloat {
        let requested = height * style.edgeInset
        guard barHeight > 0 else { return requested }
        let clearance = barHeight + SubtitleStyle.controlsClearanceGap
        switch style.controlsClearance {
        case .always:
            return max(requested, clearance)
        case .whileControlsVisible:
            return controlsShown ? max(requested, clearance) : requested
        }
    }

    /// The lines at an edge go into the letterbox band there when they fit
    /// (the window is taller than the picture, or the screen is): centred in
    /// it, off the picture. Otherwise the usual inset. The bar at that edge
    /// is kept clear the same way in both cases.
    private func bandInset(band: CGFloat, block: CGFloat, bar: CGFloat, height: CGFloat) -> CGFloat {
        let gap = SubtitleStyle.controlsClearanceGap
        guard block > 0, band >= block + 2 * gap else {
            return inset(for: height, clearing: bar)
        }
        let centred = (band - block) / 2
        guard bar > 0 else { return centred }
        let clearance = bar + gap
        switch style.controlsClearance {
        case .always:
            return max(centred, clearance)
        case .whileControlsVisible:
            return controlsShown ? max(centred, clearance) : centred
        }
    }

    /// The lines placed at that edge, ordered from the edge inwards.
    @ViewBuilder
    private func blocks(at edge: SubtitleStyle.Position, availableWidth: CGFloat) -> some View {
        let original = style.originalPosition == edge
        let translation = style.translationPosition == edge
        VStack(spacing: 8) {
            if edge == .top {
                if original { originalBlock(availableWidth: availableWidth) }
                if translation { translationBlock }
            } else {
                if translation { translationBlock }
                if original { originalBlock(availableWidth: availableWidth) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Translation line

    @ViewBuilder
    private var translationBlock: some View {
        if player.isTranslationShown && !player.secondarySubTextOnScreen.isEmpty {
            OutlinedText(
                player.secondarySubTextOnScreen,
                font: style.font(size: max(12, primaryFontSize * CGFloat(style.translationScale)), weight: .medium),
                color: style.textColor,
                outlineColor: style.outlineColor,
                outlineWidth: CGFloat(style.outlineWidth)
            )
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(subtitleBox)
            .shadow(color: .black.opacity(0.5 * boxOpacity), radius: 6, x: 0, y: 3)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeInOut(duration: 0.15), value: player.isPeekingTranslation)
        } else if player.isPeekingTranslation, let reason = player.translationUnavailableReason {
            // TAB pressed with nothing to reveal: say why, where the
            // translation would have appeared, for as long as TAB is held.
            Text(Self.unavailableMessage(for: reason))
                .font(.system(size: max(12, primaryFontSize * 0.6), weight: .medium, design: .rounded))
                .italic()
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(subtitleBox)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: player.isPeekingTranslation)
        }
    }

    static func unavailableMessage(for reason: MPVPlayer.TranslationUnavailableReason) -> String {
        switch reason {
        case .noSubtitleTracks:
            return String(localized: "This file has no subtitles — load a subtitle file with ⌘⇧O")
        case .singleTrack:
            return String(localized: "This file has only one subtitle track — load a translation with ⌘⇧O")
        case .noSecondaryTrack:
            return String(localized: "No translation track selected — pick a second track in the Subtitles menu")
        }
    }

    // MARK: - Original line (interactive words)

    @ViewBuilder
    private func originalBlock(availableWidth: CGFloat) -> some View {
        if !player.subTextOnScreen.isEmpty {
            let lines = player.subTextOnScreen
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            VStack(alignment: .center, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let rows = wrappedWordRows(for: line, availableWidth: availableWidth)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: style.spaceWidth(size: primaryFontSize)) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, word in
                                subtitleWordView(for: word)
                            }
                        }
                    }
                }
            }
            .id(wordHoverRevision)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(subtitleBox)
            // The dictionary card keeps clear of the whole pill, not just
            // the clicked word, so it never covers the line being read.
            .transformAnchorPreference(key: LookupAnchorsKey.self, value: .bounds) { $0.block = $1 }
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

    private var boxOpacity: Double { style.backgroundOpacity }

    private func resetWordHoverRegions() {
        hoveredWord = nil
        isHoveringPill = false
        wordHoverRevision &+= 1
    }

    private var explainBadge: some View {
        Button(action: {
            player.pause()
            showExplanation = true
        }) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text("AI")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.yellow))
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("Explain this line with Gemini AI (Cmd + G)")
    }

    private var primaryFontSize: CGFloat { CGFloat(player.subFontSize(forAreaHeight: areaHeight)) }

    /// Split the line before SwiftUI measures the subtitle box. A custom
    /// `Layout` can be offered an unconstrained width during measurement and
    /// a smaller width during placement; it then draws a second row outside
    /// the one-row height that the parent already accepted. Concrete HStacks
    /// make the measured box height and the rendered rows identical.
    private func wrappedWordRows(for line: String, availableWidth: CGFloat) -> [[String]] {
        let words = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        // 32 pt inside the pill, 20 pt around it for the floating AI badge,
        // and another 32 pt so glyphs and their shadow stay inside the window.
        let maximumTextWidth = max(1, availableWidth - 84)
        let font = style.nsFont(size: primaryFontSize)
        let spacing = style.spaceWidth(size: primaryFontSize)
        var rows: [[String]] = []
        var current: [String] = []
        var currentWidth: CGFloat = 0

        for word in words {
            let wordWidth = (word as NSString).size(withAttributes: [.font: font]).width
            let proposedWidth = currentWidth + (current.isEmpty ? 0 : spacing) + wordWidth
            if !current.isEmpty && proposedWidth > maximumTextWidth {
                rows.append(current)
                current = [word]
                currentWidth = wordWidth
            } else {
                current.append(word)
                currentWidth = proposedWidth
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Shared box behind the primary subtitles and the translation line.
    private var subtitleBox: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.black.opacity(boxOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15 * boxOpacity), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func subtitleWordView(for word: String) -> some View {
        let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
        let isLookedUp = lookup.word == cleanWord
        let isHovered = hoveredWord == cleanWord || isLookedUp
        OutlinedText(
            word,
            font: style.font(size: primaryFontSize),
            color: isHovered ? style.highlightColor : style.textColor,
            outlineColor: style.outlineColor,
            outlineWidth: CGFloat(style.outlineWidth)
        )
            .lineLimit(1)
            .fixedSize()
            .anchorPreference(key: LookupAnchorsKey.self, value: .bounds) {
                isLookedUp ? LookupAnchors(word: $0) : LookupAnchors()
            }
            .onHover { isHover in
                hoveredWord = isHover ? cleanWord : nil
            }
            // Click: the offline dictionary. ⌥-click: straight to the AI
            // breakdown of the line, focused on the word.
            .onTapGesture {
                guard !cleanWord.isEmpty else { return }
                if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                    onExplainWord?(cleanWord)
                } else {
                    player.pause()
                    lookup.open(cleanWord)
                }
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

    init(words: [String], horizontalSpacing: CGFloat = 5, @ViewBuilder content: @escaping (String) -> Content) {
        self.words = words
        self.horizontalSpacing = horizontalSpacing
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
