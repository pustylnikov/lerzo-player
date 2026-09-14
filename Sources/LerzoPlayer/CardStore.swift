import Foundation
import Combine
import AppKit

public enum CardKind: String, Codable {
    case word
    case phrase
}

public struct Card: Codable, Identifiable {
    public let id: UUID
    /// Stable Anki note identifier. It survives edits and repeated exports.
    public let guid: String
    public let kind: CardKind
    public var word: String?
    public var sentence: String
    public var translation: String?
    public var definition: String?
    public var contextualWordInfo: ContextualWordInfo?
    public var explanation: SubtitleExplanation?
    /// Free-form user note. Exporters append it to the Explanation field.
    public var notes: String?
    public let videoPath: String
    public var videoTitle: String
    public var time: Double
    /// File name relative to CardStore's `media` directory.
    public var screenshot: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var exportedAt: Date?
}

/// Persistent, local-only collection of vocabulary and phrase cards.
///
/// Mutations happen on the main thread because the store is observed by
/// SwiftUI. JSON encoding and file writes run off the main thread.
public final class CardStore: ObservableObject {
    public static let shared = CardStore()

    @Published public private(set) var cards: [Card] = []
    @Published public var collectsAutomatically: Bool {
        didSet { UserDefaults.standard.set(collectsAutomatically, forKey: Self.collectsAutomaticallyKey) }
    }

    private static let collectsAutomaticallyKey = "LerzoPlayer.collectCardsAutomatically"
    private static let saveDelay: TimeInterval = 0.35

    public let directoryURL: URL
    public let mediaDirectoryURL: URL
    public let cardsFileURL: URL

    private let fileQueue = DispatchQueue(label: "com.lerzo.player.cards", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.collectsAutomaticallyKey) == nil {
            collectsAutomatically = true
        } else {
            collectsAutomatically = defaults.bool(forKey: Self.collectsAutomaticallyKey)
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first!
        directoryURL = applicationSupport.appendingPathComponent("Lerzo Player", isDirectory: true)
        mediaDirectoryURL = directoryURL.appendingPathComponent("media", isDirectory: true)
        cardsFileURL = directoryURL.appendingPathComponent("cards.json")

        createDirectories()
        cards = Self.load(from: cardsFileURL)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveImmediately()
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Save the subtitle currently visible in the player. Automatic calls
    /// respect the preference; the S shortcut passes `automatic: false`.
    @discardableResult
    public func recordCurrent(kind: CardKind,
                              word: String? = nil,
                              definition: String? = nil,
                              contextualWordInfo: ContextualWordInfo? = nil,
                              explanation: SubtitleExplanation? = nil,
                              wordContextSensitive: Bool = false,
                              automatic: Bool = true) -> Card? {
        if automatic && !collectsAutomatically { return nil }

        let player = MPVPlayer.shared
        guard let videoURL = player.currentFileURL else { return nil }
        let sentence = player.subTextOnScreen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }

        let cleanWord = word?.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .word && (cleanWord?.isEmpty != false) { return nil }
        let translation = player.secondarySubTextOnScreen.trimmingCharacters(in: .whitespacesAndNewlines)

        return record(
            kind: kind,
            word: cleanWord,
            sentence: sentence,
            translation: translation.isEmpty ? nil : translation,
            definition: definition,
            contextualWordInfo: contextualWordInfo,
            explanation: explanation,
            wordContextSensitive: wordContextSensitive,
            videoURL: videoURL,
            videoTitle: player.mediaTitle,
            time: player.currentTime,
            captureScreenshot: true
        )
    }

    /// Lower-level entry point kept independent of the player for editing,
    /// importing and tests. Existing cards retain their original context and
    /// only have missing fields filled in.
    @discardableResult
    public func record(kind: CardKind,
                       word: String?,
                       sentence: String,
                       translation: String?,
                       definition: String?,
                       contextualWordInfo: ContextualWordInfo? = nil,
                       explanation: SubtitleExplanation?,
                       wordContextSensitive: Bool = false,
                       videoURL: URL,
                       videoTitle: String,
                       time: Double,
                       captureScreenshot: Bool) -> Card {
        dispatchPrecondition(condition: .onQueue(.main))

        let now = Date()
        let path = videoURL.standardizedFileURL.path
        let contextSensitive = kind == .word && (wordContextSensitive || contextualWordInfo != nil)
        let key = deduplicationKey(kind: kind, word: word, sentence: sentence,
                                   videoPath: path, wordContextSensitive: contextSensitive)
        var cardID: UUID
        var shouldCapture = false

        if let index = cards.firstIndex(where: {
            let existingContextSensitive = $0.kind == .word && contextSensitive
            return deduplicationKey(kind: $0.kind, word: $0.word, sentence: $0.sentence,
                                    videoPath: $0.videoPath,
                                    wordContextSensitive: existingContextSensitive) == key
        }) {
            cards[index].lastUsedAt = now
            if cards[index].translation?.isEmpty != false { cards[index].translation = nonEmpty(translation) }
            if cards[index].definition?.isEmpty != false { cards[index].definition = nonEmpty(definition) }
            if cards[index].contextualWordInfo == nil && cards[index].sentence == sentence {
                cards[index].contextualWordInfo = contextualWordInfo
            }
            if cards[index].explanation == nil { cards[index].explanation = explanation }
            if cards[index].videoTitle.isEmpty { cards[index].videoTitle = videoTitle }
            cardID = cards[index].id
            shouldCapture = cards[index].screenshot == nil
        } else {
            let card = Card(
                id: UUID(),
                guid: UUID().uuidString.lowercased(),
                kind: kind,
                word: nonEmpty(word),
                sentence: sentence,
                translation: nonEmpty(translation),
                definition: nonEmpty(definition),
                contextualWordInfo: contextualWordInfo,
                explanation: explanation,
                notes: nil,
                videoPath: path,
                videoTitle: videoTitle.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : videoTitle,
                time: time,
                screenshot: nil,
                createdAt: now,
                lastUsedAt: now,
                exportedAt: nil
            )
            cards.append(card)
            cardID = card.id
            shouldCapture = true
        }

        scheduleSave()
        if captureScreenshot && shouldCapture {
            captureFrame(for: cardID)
        }
        return cards.first(where: { $0.id == cardID })!
    }

    /// Compact dictionary text for a card: headings plus at most three
    /// definitions, never usage examples or the trailing dictionary sections.
    public static func compactDefinition(from lines: [DefinitionLine], maximumMeanings: Int = 3) -> String? {
        guard maximumMeanings > 0 else { return nil }
        var output: [String] = []
        var pendingPartOfSpeech: String?
        var meanings = 0

        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .partOfSpeech:
                pendingPartOfSpeech = line.text
            case .sense(let number) where meanings < maximumMeanings:
                let text = dictionaryGloss(line.text)
                guard !text.isEmpty else { continue }
                if let heading = pendingPartOfSpeech {
                    output.append(heading)
                    pendingPartOfSpeech = nil
                }
                output.append("\(number). \(text)")
                meanings += 1
            case .plain where index > 0 && meanings < maximumMeanings:
                let text = dictionaryGloss(line.text)
                guard !text.isEmpty else { continue }
                if let heading = pendingPartOfSpeech {
                    output.append(heading)
                    pendingPartOfSpeech = nil
                }
                output.append(text)
                meanings += 1
            default:
                break
            }
            if meanings == maximumMeanings { break }
        }

        // Some dictionaries return a single unstructured line. It is more
        // useful than an empty Definition field, even if it includes a headword.
        if output.isEmpty, let line = lines.first(where: {
            if case .plain = $0.kind { return !$0.text.isEmpty }
            return false
        }) {
            output.append(dictionaryGloss(line.text))
        }
        let result = output.filter { !$0.isEmpty }.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    public func card(withID id: UUID) -> Card? {
        cards.first(where: { $0.id == id })
    }

    public func update(_ card: Card) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        var edited = card
        edited.lastUsedAt = Date()
        cards[index] = edited
        scheduleSave()
    }

    /// Removes cards and returns their values so a row deletion can be undone.
    /// Media is deliberately retained until `discardMedia` is called.
    @discardableResult
    public func remove(ids: Set<UUID>) -> [Card] {
        dispatchPrecondition(condition: .onQueue(.main))
        let removed = cards.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        cards.removeAll { ids.contains($0.id) }
        scheduleSave()
        return removed
    }

    public func restore(_ removed: [Card]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let existing = Set(cards.map(\.id))
        cards.append(contentsOf: removed.filter { !existing.contains($0.id) })
        cards.sort { $0.createdAt < $1.createdAt }
        scheduleSave()
    }

    public func discardMedia(for removed: [Card]) {
        let names = removed.compactMap(\.screenshot)
        guard !names.isEmpty else { return }
        fileQueue.async { [mediaDirectoryURL] in
            for name in names {
                try? FileManager.default.removeItem(at: mediaDirectoryURL.appendingPathComponent(name))
            }
        }
    }

    public func newCount(for videoURL: URL?) -> Int {
        guard let path = videoURL?.standardizedFileURL.path else { return 0 }
        return cards.lazy.filter { $0.videoPath == path && $0.exportedAt == nil }.count
    }

    public func removeAllCards() -> [Card] {
        remove(ids: Set(cards.map(\.id)))
    }

    public func markExported(ids: Set<UUID>, at date: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        var changed = false
        for index in cards.indices where ids.contains(cards[index].id) {
            cards[index].exportedAt = date
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Flushes the latest snapshot synchronously. Used when the app exits.
    public func saveImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = cards
        fileQueue.sync { Self.write(snapshot, to: cardsFileURL) }
    }

    private func captureFrame(for cardID: UUID) {
        MPVPlayer.shared.captureCurrentFrameJPEG { [weak self] data in
            guard let self, let data else { return }
            let name = "\(cardID.uuidString.lowercased()).jpg"
            let url = self.mediaDirectoryURL.appendingPathComponent(name)
            self.fileQueue.async {
                do {
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let index = self.cards.firstIndex(where: { $0.id == cardID }) else { return }
                        self.cards[index].screenshot = name
                        self.scheduleSave()
                    }
                } catch {
                    NSLog("Lerzo Player: could not save card screenshot: %@", error.localizedDescription)
                }
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = cards
        let url = cardsFileURL
        let work = DispatchWorkItem { Self.write(snapshot, to: url) }
        pendingSave = work
        fileQueue.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func createDirectories() {
        do {
            try FileManager.default.createDirectory(at: mediaDirectoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            NSLog("Lerzo Player: could not create cards directory: %@", error.localizedDescription)
        }
    }

    private static func load(from url: URL) -> [Card] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Card].self, from: data)
        } catch {
            NSLog("Lerzo Player: could not read cards.json: %@", error.localizedDescription)
            return []
        }
    }

    private static func write(_ cards: [Card], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(cards)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Lerzo Player: could not save cards.json: %@", error.localizedDescription)
        }
    }

    private func deduplicationKey(kind: CardKind,
                                  word: String?,
                                  sentence: String,
                                  videoPath: String,
                                  wordContextSensitive: Bool) -> String {
        let value: String
        if kind == .word {
            value = wordContextSensitive ? "\(word ?? "")\u{1f}\(sentence)" : (word ?? "")
        } else {
            value = sentence
        }
        let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind.rawValue)\u{1f}\(videoPath)\u{1f}\(normalized)"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dictionaryGloss(_ text: String) -> String {
        var text = text
        if let colon = text.range(of: ": ") { text = String(text[..<colon.lowerBound]) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
    }
}
