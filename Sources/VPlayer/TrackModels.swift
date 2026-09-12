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
    
    public var displayName: String {
        var name = title.isEmpty ? (lang?.uppercased() ?? "Track \(id)") : title
        if let lang = lang, !title.isEmpty {
            name += " (\(lang.uppercased()))"
        }
        if isSelected {
            name += " ✓"
        }
        return name
    }
}

public enum PlaybackState {
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
