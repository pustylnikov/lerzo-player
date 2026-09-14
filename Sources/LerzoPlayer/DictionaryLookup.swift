import SwiftUI
import AppKit
import CoreServices

/// Offline word lookup through the macOS Dictionary Services. Which
/// dictionaries answer (and in what order) is whatever the user enabled in
/// Dictionary.app, so a bilingual dictionary there gives translations here.
enum SystemDictionary {
    /// The entry for `word`, or nil when no active dictionary knows it.
    /// Sentence-initial capitals are retried in lowercase.
    static func definition(for word: String, stripStressMarks: Bool) -> [DefinitionLine]? {
        let candidates = [word, word.lowercased()]
        for candidate in candidates.uniqued() {
            let term = candidate as NSString as CFString
            let range = CFRangeMake(0, candidate.utf16.count)
            if let text = DCSCopyTextDefinition(nil, term, range)?.takeRetainedValue() {
                var raw = text as NSString as String
                // Bilingual entries stress every Russian word (зе́мля); a native
                // speaker reads faster without the marks.
                if stripStressMarks { raw = raw.replacingOccurrences(of: "\u{0301}", with: "") }
                return lines(from: raw)
            }
        }
        return nil
    }

    /// Part-of-speech labels as Apple's dictionaries print them; only
    /// recognised right after a pronunciation, a bracket or a Cyrillic word,
    /// so "collective noun" inside a definition stays put.
    private static let partsOfSpeech = [
        "transitive verb", "intransitive verb", "reflexive verb", "auxiliary verb", "modal verb",
        "plural noun", "noun", "verb", "adjective", "adverb", "pronoun", "preposition",
        "conjunction", "exclamation", "interjection", "determiner", "abbreviation",
        "prefix", "suffix", "combining form",
    ]
    private static let sections = ["PHRASES", "PHRASAL VERBS", "DERIVATIVES", "ORIGIN", "USAGE"]

    /// The flat text runs everything together: senses, sub-senses, examples
    /// and parts of speech get their own lines, typed for the card to style.
    static func lines(from raw: String) -> [DefinitionLine] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Examples (Oxford bilingual: "▸", often glued to the previous word)
        // and sub-senses (Oxford monolingual: "•").
        text = text.replacingOccurrences(of: #"\s*▸\s*"#, with: "\n▸ ", options: .regularExpression)
        text = text.replacingOccurrences(of: " • ", with: "\n• ")
        text = splitSenses(in: text)
        // Parts of speech: before a sense number, or heading a definition.
        let pos = partsOfSpeech.joined(separator: "|")
        let before = #"(?<=\| |\) |\] |\. |[\p{Cyrillic}\p{M}] )"#
        text = text.replacingOccurrences(
            of: before + "(" + pos + #")(?=\n)"#, with: "\n$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: before + "(" + pos + #") (?=[\[(\p{L}])"#, with: "\n$1\n", options: .regularExpression)
        // Trailing sections of the monolingual entries.
        text = text.replacingOccurrences(
            of: #"(?<=\S) ("# + sections.joined(separator: "|") + #")\b"#,
            with: "\n$1\n", options: .regularExpression)

        return text.components(separatedBy: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("▸") { return DefinitionLine(kind: .example, text: line) }
            if line.hasPrefix("•") { return DefinitionLine(kind: .subsense, text: line) }
            if partsOfSpeech.contains(line) { return DefinitionLine(kind: .partOfSpeech, text: line) }
            if sections.contains(line) { return DefinitionLine(kind: .section, text: line) }
            if let match = line.range(of: #"^\d{1,2}(?: |:$)"#, options: .regularExpression) {
                return DefinitionLine(kind: .sense(number: String(line[match].dropLast())),
                                      text: String(line[match.upperBound...]))
            }
            return DefinitionLine(kind: .plain, text: line)
        }
    }

    /// Sense numbers run 1, 2, 3… within a part of speech and start over at
    /// the next one; a number out of sequence ("a 5 percent rise", "(sense 2
    /// of the noun)") is part of the text and stays inline.
    private static func splitSenses(in text: String) -> String {
        // "2:" is a sense with examples only (bilingual entries).
        let pattern = try! NSRegularExpression(pattern: #"(?<=\S) (\d{1,2})(?: (?=[\[(\p{L}])|:(?=\n))"#)
        let source = text as NSString
        let result = NSMutableString(string: text)
        var expected = 1
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let number = Int(source.substring(with: match.range(at: 1)))!
            let start = match.range.location
            let preceding = source.substring(with: NSRange(location: max(0, start - 8), length: min(8, start))).lowercased()
            guard number == expected || number == 1,
                  !preceding.hasSuffix("sense"), !preceding.hasSuffix("senses")
            else { continue }
            expected = number + 1
            // "\n" replaces the space before the number: same length, so
            // later match offsets stay valid.
            result.replaceCharacters(in: NSRange(location: start, length: 1), with: "\n")
        }
        return result as String
    }

    /// Full entry with pictures and every dictionary, in Dictionary.app.
    static func openInDictionaryApp(_ word: String) {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One line of a formatted dictionary entry.
public struct DefinitionLine: Equatable {
    public enum Kind: Equatable {
        case plain
        case partOfSpeech
        case section
        case sense(number: String)
        case subsense
        case example
    }
    public let kind: Kind
    public let text: String
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

public enum WordLookupSource: String, CaseIterable, Identifiable {
    case dictionary
    case gemini
    case combined

    public var id: String { rawValue }
    public var usesDictionary: Bool { self != .gemini }
    public var usesGemini: Bool { self != .dictionary }
}

/// The word whose dictionary card is open, shared so the keyboard monitor
/// can close it and the subtitles layer can draw it next to the word.
public final class DictionaryLookup: ObservableObject {
    public static let shared = DictionaryLookup()

    public enum Result: Equatable {
        case loading
        case found([DefinitionLine])
        case notFound
    }

    public enum GeminiResult {
        case idle
        case loading
        case found(ContextualWordInfo, model: String, cached: Bool, usage: GeminiService.TokenUsage?)
        case failed(GeminiError)
    }

    @Published public private(set) var word: String?
    @Published public private(set) var result: Result = .loading
    @Published public private(set) var geminiResult: GeminiResult = .idle
    @Published public var source: WordLookupSource = {
        let raw = UserDefaults.standard.string(forKey: "LerzoPlayer.wordLookupSource")
        return raw.flatMap(WordLookupSource.init(rawValue:)) ?? .dictionary
    }() {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "LerzoPlayer.wordLookupSource") }
    }
    private var geminiTask: Task<Void, Never>?

    public var isOpen: Bool { word != nil }

    public func open(_ word: String) {
        geminiTask?.cancel()
        self.word = word
        result = source.usesDictionary ? .loading : .notFound
        geminiResult = source.usesGemini ? .loading : .idle

        if source.usesDictionary {
            let stripStress = LanguagePreferences.shared.resolvedNativeCode == "ru"
            let wordContextSensitive = source.usesGemini
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = SystemDictionary.definition(for: word, stripStressMarks: stripStress)
                DispatchQueue.main.async {
                    guard self.word == word else { return }
                    self.result = lines.map(Result.found) ?? .notFound
                    if let lines {
                        CardStore.shared.recordCurrent(
                            kind: .word,
                            word: word,
                            definition: CardStore.compactDefinition(from: lines),
                            wordContextSensitive: wordContextSensitive
                        )
                    }
                }
            }
        }

        if source.usesGemini {
            let player = MPVPlayer.shared
            let sentence = player.subTextOnScreen.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitleTranslation = player.secondarySubTextOnScreen
                .trimmingCharacters(in: .whitespacesAndNewlines)
            geminiTask = Task { @MainActor in
                do {
                    // Avoid paying for a click immediately superseded by another.
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try Task.checkCancellation()
                    guard !sentence.isEmpty else {
                        throw GeminiError.other(String(localized: "There are no subtitles right now."))
                    }
                    let response = try await GeminiService.shared.translateWord(
                        word,
                        in: sentence,
                        subtitleTranslation: subtitleTranslation.isEmpty ? nil : subtitleTranslation
                    )
                    try Task.checkCancellation()
                    guard self.word == word else { return }
                    self.geminiResult = .found(response.info, model: response.model,
                                               cached: response.cached, usage: response.usage)
                    CardStore.shared.recordCurrent(
                        kind: .word,
                        word: word,
                        contextualWordInfo: response.info,
                        wordContextSensitive: true
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.word == word else { return }
                    self.geminiResult = .failed(GeminiError.from(transport: error))
                }
            }
        }
    }

    public func close() {
        geminiTask?.cancel()
        geminiTask = nil
        word = nil
        geminiResult = .idle
    }
}

/// Bounds of the word whose card is open, reported by the subtitles layer.
struct LookedUpWordAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// Places the card over the clicked word (under it when the line is at the
/// top), centred on the word but kept inside the area, above every other
/// layer. A transparent catcher behind it closes the card on a click
/// elsewhere. `anchor` comes from the subtitles layer's preference.
struct DictionaryCardOverlay: View {
    @ObservedObject var lookup = DictionaryLookup.shared
    let anchor: Anchor<CGRect>
    var onExplain: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            if let word = lookup.word {
                let wordRect = geo[anchor]
                let size = geo.size
                let width = DictionaryCardView.width
                let gap: CGFloat = 8
                let margin: CGFloat = 12
                let x = min(max(wordRect.midX, width / 2 + margin), size.width - width / 2 - margin)
                let above = wordRect.midY > size.height / 2
                let card = DictionaryCardView(word: word) {
                    lookup.close()
                    onExplain(word)
                }
                ZStack {
                    Color.black.opacity(0.001)
                        .onTapGesture { lookup.close() }
                    if above {
                        let height = max(0, wordRect.minY - gap)
                        card
                            .frame(width: width, height: height, alignment: .bottom)
                            .position(x: x, y: height / 2)
                    } else {
                        let top = wordRect.maxY + gap
                        let height = max(0, size.height - top)
                        card
                            .frame(width: width, height: height, alignment: .top)
                            .position(x: x, y: top + height / 2)
                    }
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: lookup.word)
    }
}

/// Definition card shown next to the clicked word.
struct DictionaryCardView: View {
    @ObservedObject var lookup = DictionaryLookup.shared
    @ObservedObject private var gemini = GeminiService.shared
    let word: String
    var onExplain: () -> Void

    static let width: CGFloat = 400
    static let maxTextHeight: CGFloat = 220
    /// Senses shown per part of speech in the compact view.
    static let compactSensesPerPart = 6
    @State private var showsFullEntry = false
    @State private var showsDictionaryInCombined = false
    @State private var showsTokenTooltip = false
    @State private var tokenTooltipTask: Task<Void, Never>?

    /// The glance view: the headword line, parts of speech and their first
    /// senses with any trailing example cut off; no sub-senses, examples or
    /// sections. A sense that is only examples shows its first example.
    static func compactLines(_ lines: [DefinitionLine]) -> [DefinitionLine] {
        var result: [DefinitionLine] = []
        var sensesInPart = 0
        var previousKind: DefinitionLine.Kind = .plain
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .partOfSpeech:
                result.append(line)
                sensesInPart = 0
            case .plain where index == 0 || previousKind == .partOfSpeech:
                result.append(DefinitionLine(kind: .plain, text: index == 0 ? line.text : gloss(line.text)))
            case .sense(let number) where sensesInPart < compactSensesPerPart:
                var text = gloss(line.text)
                if text.isEmpty, let example = lines.dropFirst(index + 1).first, example.kind == .example {
                    text = String(example.text.dropFirst(2))   // "▸ "
                }
                result.append(DefinitionLine(kind: .sense(number: number), text: text))
                sensesInPart += 1
            default:
                break
            }
            previousKind = line.kind
        }
        return result
    }

    /// The definition without the example that follows the colon.
    private static func gloss(_ text: String) -> String {
        var text = text
        if let colon = text.range(of: ": ") { text = String(text[..<colon.lowerBound]) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
    }
    private static let padding: CGFloat = 14
    private static let lineGap: CGFloat = 3

    /// How each kind of line is drawn; the same numbers size the scroll view.
    private static func style(for kind: DefinitionLine.Kind) -> (font: NSFont, indent: CGFloat, topGap: CGFloat, opacity: Double) {
        switch kind {
        case .plain: return (.systemFont(ofSize: 13), 0, 0, 0.92)
        case .partOfSpeech, .section: return (.systemFont(ofSize: 11, weight: .bold), 0, 6, 1)
        case .sense: return (.systemFont(ofSize: 13), 0, 2, 0.92)
        case .subsense: return (.systemFont(ofSize: 13), 10, 0, 0.85)
        case .example: return (.systemFont(ofSize: 12.5), 14, 0, 0.62)
        }
    }

    /// Laid-out height of the entry at the card's text width, measured with
    /// AppKit so the scroll view can be sized before SwiftUI lays it out.
    private static func height(of lines: [DefinitionLine]) -> CGFloat {
        let width = Self.width - 2 * padding
        var total: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let style = style(for: line.kind)
            var text = line.text
            if case .sense(let number) = line.kind { text = number + "  " + text }
            let bounds = NSAttributedString(string: text, attributes: [.font: style.font]).boundingRect(
                with: CGSize(width: width - style.indent, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            total += ceil(bounds.height) + style.topGap + (index > 0 ? lineGap : 0)
        }
        return total + 4
    }

    @ViewBuilder
    private func lineView(_ line: DefinitionLine) -> some View {
        let style = Self.style(for: line.kind)
        Group {
            switch line.kind {
            case .partOfSpeech, .section:
                Text(line.text.uppercased())
                    .foregroundColor(.yellow)
            case .sense(let number):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number).fontWeight(.bold).foregroundColor(.yellow)
                    Text(line.text).foregroundColor(.white.opacity(style.opacity))
                }
            default:
                Text(line.text).foregroundColor(.white.opacity(style.opacity))
            }
        }
        .font(Font(style.font))
        .padding(.leading, style.indent)
        .padding(.top, style.topGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: lookup.source == .dictionary ? "character.book.closed.fill" : "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.yellow)
                Text(word)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Button(action: { lookup.close() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            switch lookup.source {
            case .dictionary:
                dictionaryContent(maxHeight: Self.maxTextHeight)
            case .gemini:
                geminiContent
            case .combined:
                geminiContent
                Button {
                    showsDictionaryInCombined.toggle()
                } label: {
                    HStack {
                        Image(systemName: showsDictionaryInCombined ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(showsDictionaryInCombined ? "Hide macOS dictionary" : "Show macOS dictionary")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                if showsDictionaryInCombined {
                    dictionaryContent(maxHeight: 150)
                }
            }

            HStack {
                Button(action: { SystemDictionary.openInDictionaryApp(word) }) {
                    HStack(spacing: 4) {
                        Text("Dictionary app")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Open the full entry in Dictionary.app")

                Spacer()

                Button(action: onExplain) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("AI breakdown")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow))
                }
                .buttonStyle(.plain)
                .help("Explain the whole line with Gemini, focused on this word (⌥-click a word does the same)")
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 6)
        .onChange(of: word) { _, _ in
            showsFullEntry = false
            showsDictionaryInCombined = false
            tokenTooltipTask?.cancel()
            showsTokenTooltip = false
        }
        .onDisappear { tokenTooltipTask?.cancel() }
    }

    @ViewBuilder
    private func dictionaryContent(maxHeight: CGFloat) -> some View {
        switch lookup.result {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .colorInvert()
                .frame(maxWidth: .infinity, minHeight: 40)
        case .found(let fullLines):
            let lines = showsFullEntry ? fullLines : Self.compactLines(fullLines)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Self.lineGap) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(height: min(Self.height(of: lines), maxHeight))
            if lines.count < fullLines.count || showsFullEntry {
                Button(showsFullEntry ? "Short entry" : "Full entry with examples") {
                    showsFullEntry.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.yellow.opacity(0.85))
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 4) {
                Text("Not in your dictionaries.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Text("Dictionaries for each language are turned on in Dictionary ▸ Settings; a bilingual one shows translations here.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var geminiContent: some View {
        switch lookup.geminiResult {
        case .idle:
            EmptyView()
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small).colorInvert()
                Text("Gemini is translating the word in context…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        case .found(let info, let model, let cached, let usage):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.meaningInContext)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                    Spacer()
                }
                let details = [info.lemma, info.partOfSpeech].filter { !$0.isEmpty }.joined(separator: " · ")
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.yellow.opacity(0.82))
                }
                if !info.definition.isEmpty {
                    Text(info.definition)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.82))
                        .textSelection(.enabled)
                }
                if !info.otherMeanings.isEmpty {
                    Text("Other meanings: \(info.otherMeanings.joined(separator: " · "))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.66))
                        .textSelection(.enabled)
                }
                if !info.synonyms.isEmpty {
                    Text("Synonyms: \(info.synonyms.joined(separator: " · "))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.66))
                        .textSelection(.enabled)
                }
                geminiFooter(model: model, cached: cached, usage: usage)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text(error.errorDescription ?? String(localized: "Gemini could not translate this word."))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                if let hint = error.recoverySuggestion {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        }
    }

    private func geminiFooter(model: String,
                              cached: Bool,
                              usage: GeminiService.TokenUsage?) -> some View {
        let help = geminiFooterHelp(cached: cached, usage: usage)
        return HStack(spacing: 4) {
            Text(model)
            if cached {
                Text("·")
                Image(systemName: "bolt.horizontal.circle")
                Text("Local cache")
                Text("·")
                Text("\(0) tokens")
            } else if let usage {
                Text("·")
                Text("\(usage.total) tokens")
            }
        }
        .font(.system(size: 9))
        .foregroundColor(.white.opacity(0.32))
        .contentShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
            if showsTokenTooltip, !help.isEmpty {
                Text(help)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.94))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                    .offset(y: -18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .onHover { hovering in
            tokenTooltipTask?.cancel()
            if hovering, !help.isEmpty {
                tokenTooltipTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 250_000_000) }
                    catch { return }
                    withAnimation(.easeOut(duration: 0.1)) { showsTokenTooltip = true }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) { showsTokenTooltip = false }
            }
        }
    }

    private func geminiFooterHelp(cached: Bool,
                                  usage: GeminiService.TokenUsage?) -> String {
        if cached { return String(localized: "Loaded from the local cache") }
        guard let usage else { return "" }
        let request = String(localized: "Prompt \(usage.prompt), answer \(usage.output), thinking \(usage.thoughts) tokens")
        let session = String(localized: "· session \(gemini.sessionUsage.total)")
        return "\(request) \(session)"
    }
}
