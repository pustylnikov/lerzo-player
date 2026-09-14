import Foundation

public enum TrackType: String, Codable {
    case video
    case audio
    case sub
}

public struct MediaTrack: Identifiable, Hashable {
    public let id: Int
    public let type: TrackType
    public let title: String
    public let lang: String?
    public let isDefault: Bool
    public let isSelected: Bool
    public let isExternal: Bool
    /// "Forced" subtitle tracks only carry a few lines (foreign speech, signs)
    /// and must not be picked as the main track for the language.
    public var isForced: Bool = false
    /// libavformat's stream index inside its own file (mpv's `ff-index`).
    public var ffIndex: Int? = nil
    /// Path of the file an external subtitle track was loaded from.
    public var externalFilename: String? = nil
    
    public var displayName: String {
        var name = title.isEmpty ? (lang?.uppercased() ?? String(localized: "Track \(id)")) : title
        if let lang = lang, !title.isEmpty {
            name += " (\(lang.uppercased()))"
        }
        return name
    }
}

public enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case finished
}

public struct SubtitleExplanation: Codable {
    public let sentence: String
    public let translation: String
    public let idioms: [IdiomExplanation]
    public let difficultWords: [WordExplanation]
    public let contextNote: String?
    /// Optional for compatibility with phrase cards saved before these
    /// sections were added to the Gemini response.
    public let grammar: [GrammarExplanation]?
    public let customSections: [CustomExplanationSection]?
}

public struct IdiomExplanation: Codable, Identifiable {
    public var id: String { idiom }
    public let idiom: String
    public let literalMeaning: String
    public let actualMeaning: String
}

public struct WordExplanation: Codable, Identifiable {
    public var id: String { word }
    public let word: String
    public let translation: String
    public let partOfSpeech: String?
}

public struct GrammarExplanation: Codable, Identifiable {
    public var id: String { fragment }
    public let fragment: String
    public let explanation: String
}

public struct CustomExplanationSection: Codable, Identifiable {
    public var id: String { title }
    public let title: String
    public let content: String
}

/// A compact, structured Gemini answer for one word in its subtitle context.
/// It is stored separately from the macOS dictionary entry so the UI and
/// exporters can choose either source without mixing their text.
public struct ContextualWordInfo: Codable, Equatable {
    public let lemma: String
    public let partOfSpeech: String
    public let meaningInContext: String
    public let otherMeanings: [String]
    public let definition: String
    public let synonyms: [String]

    public var plainText: String {
        var lines = [meaningInContext]
        if !definition.isEmpty { lines.append(definition) }
        if !otherMeanings.isEmpty {
            lines.append(String(localized: "Other meanings: \(otherMeanings.joined(separator: " · "))"))
        }
        if !synonyms.isEmpty {
            lines.append(String(localized: "Synonyms: \(synonyms.joined(separator: " · "))"))
        }
        return lines.joined(separator: "\n")
    }
}
