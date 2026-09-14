import SwiftUI
import AppKit
import CoreServices

/// Offline word lookup through the macOS Dictionary Services. Which
/// dictionaries answer (and in what order) is whatever the user enabled in
/// Dictionary.app, so a bilingual dictionary there gives translations here.
enum SystemDictionary {
    /// The entry for `word` as flat text, or nil when no active dictionary
    /// knows it. Sentence-initial capitals are retried in lowercase.
    static func definition(for word: String) -> String? {
        let candidates = [word, word.lowercased()]
        for candidate in candidates.uniqued() {
            let term = candidate as NSString as CFString
            let range = CFRangeMake(0, candidate.utf16.count)
            if let text = DCSCopyTextDefinition(nil, term, range)?.takeRetainedValue() {
                return format(text as NSString as String)
            }
        }
        return nil
    }

    /// The flat text runs every sense together; give the senses, sub-senses
    /// and the trailing sections their own lines.
    private static func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: " • ", with: "\n• ")
        text = text.replacingOccurrences(
            of: #"(?<=\S) (\d{1,2}) (?=[\[(\p{L}])"#, with: "\n$1 ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?<=\S) (PHRASES|PHRASAL VERBS|DERIVATIVES|ORIGIN|USAGE)\b"#, with: "\n\n$1", options: .regularExpression)
        return text
    }

    /// Full entry with pictures and every dictionary, in Dictionary.app.
    static func openInDictionaryApp(_ word: String) {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// The word whose dictionary card is open, shared so the keyboard monitor
/// can close it and the subtitles layer can draw it next to the word.
public final class DictionaryLookup: ObservableObject {
    public static let shared = DictionaryLookup()

    public enum Result: Equatable {
        case loading
        case found(String)
        case notFound
    }

    @Published public private(set) var word: String?
    @Published public private(set) var result: Result = .loading

    public var isOpen: Bool { word != nil }

    public func open(_ word: String) {
        self.word = word
        result = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            let text = SystemDictionary.definition(for: word)
            DispatchQueue.main.async {
                guard self.word == word else { return }
                self.result = text.map(Result.found) ?? .notFound
            }
        }
    }

    public func close() {
        word = nil
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
    let word: String
    var onExplain: () -> Void

    static let width: CGFloat = 400
    static let maxTextHeight: CGFloat = 220
    private static let textSize: CGFloat = 13
    private static let lineSpacing: CGFloat = 2
    private static let padding: CGFloat = 14

    /// Laid-out height of the definition at the card's text width, measured
    /// with AppKit so the scroll view can be sized before SwiftUI lays it out.
    private static func height(of text: String) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: textSize),
            .paragraphStyle: paragraph,
        ])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height) + 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "character.book.closed.fill")
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

            switch lookup.result {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .colorInvert()
                    .frame(maxWidth: .infinity, minHeight: 40)
            case .found(let text):
                // The scroll view takes only what the text needs, up to a cap.
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: Self.textSize))
                        .lineSpacing(Self.lineSpacing)
                        .foregroundColor(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(Self.height(of: text), Self.maxTextHeight))
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
    }
}
