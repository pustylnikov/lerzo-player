import Foundation
import CryptoKit

struct WordTranslationCacheDescriptor: Codable {
    let word: String
    let sentence: String
    let subtitleTranslation: String?
    let learningLanguage: String
    let nativeLanguage: String
    let model: String
    let reasoning: GeminiReasoningLevel
    let cacheVersion: Int
}

/// Small persistent LRU cache for contextual word translations. Only the
/// SHA-256 request key and the successful answer are stored; the original
/// subtitle text is not duplicated in the cache file.
actor WordTranslationCache {
    static let shared = WordTranslationCache()
    static let version = 1
    private static let maximumEntries = 500

    private struct Entry: Codable {
        var value: ContextualWordInfo
        var lastAccessedAt: Date
    }

    private struct Payload: Codable {
        let version: Int
        var entries: [String: Entry]
    }

    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private var didLoad = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        fileURL = support
            .appendingPathComponent("Lerzo Player", isDirectory: true)
            .appendingPathComponent("word-translation-cache.json")
    }

    func key(for descriptor: WordTranslationCacheDescriptor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(descriptor)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func value(forKey key: String) -> ContextualWordInfo? {
        loadIfNeeded()
        guard var entry = entries[key] else { return nil }
        entry.lastAccessedAt = Date()
        entries[key] = entry
        return entry.value
    }

    func insert(_ value: ContextualWordInfo, forKey key: String) {
        loadIfNeeded()
        entries[key] = Entry(value: value, lastAccessedAt: Date())
        if entries.count > Self.maximumEntries {
            let keep = entries.sorted { $0.value.lastAccessedAt > $1.value.lastAccessedAt }
                .prefix(Self.maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        save()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.version else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        entries = payload.entries
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Payload(version: Self.version, entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache failure must never break translation.
        }
    }
}
