import Foundation

/// A track the user picked by hand, recognisable when the file is reopened.
public enum RememberedTrack: Codable, Equatable {
    case off
    /// mpv numbers a file's own tracks the same way every time; the language
    /// and title guard against a remux that reordered them.
    case embedded(id: Int, lang: String?, title: String)
    /// A subtitle file, loaded by hand or picked up next to the video.
    case external(path: String)

    init(_ track: MediaTrack) {
        if track.isExternal, let path = track.externalFilename {
            self = .external(path: Self.normalized(path))
        } else {
            self = .embedded(id: track.id, lang: track.lang, title: track.title)
        }
    }

    func matches(_ track: MediaTrack) -> Bool {
        switch self {
        case .off:
            return false
        case let .embedded(id, lang, title):
            return !track.isExternal && track.id == id && track.lang == lang && track.title == title
        case let .external(path):
            return track.externalFilename.map(Self.normalized) == path
        }
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Adjustments made for one file that would otherwise have to be redone
/// every time it is opened.
public struct FileSettings: FileRecord {
    public let path: String
    public var fileSize: Int64?
    public var updatedAt: Date
    /// Non-zero delays, keyed by mpv property (`sub-delay`, `audio-delay`…).
    public var delays: [String: Double]?
    /// Subtitle files the user loaded by hand, in the order they were added.
    public var externalSubtitles: [String]?
    /// Tracks picked by hand, keyed by mpv property (`aid`, `sid`,
    /// `secondary-sid`); the rest follow the language preferences.
    public var tracks: [String: RememberedTrack]?

    var isEmpty: Bool {
        delays == nil && externalSubtitles == nil && tracks == nil
    }

    mutating func setDelay(_ value: Double, for property: String) {
        var delays = self.delays ?? [:]
        delays[property] = value == 0 ? nil : value
        self.delays = delays.isEmpty ? nil : delays
    }

    mutating func addExternalSubtitle(_ path: String) {
        let path = RememberedTrack.normalized(path)
        var files = externalSubtitles ?? []
        guard !files.contains(path) else { return }
        files.append(path)
        externalSubtitles = files
    }

    mutating func setTrack(_ track: RememberedTrack, for property: String) {
        var tracks = self.tracks ?? [:]
        tracks[property] = track
        self.tracks = tracks
    }
}

/// Per-file delays, subtitle files and tracks, in `file-settings.json`: kept
/// apart from the positions so that versions which only know positions can
/// still read theirs. Unlike a position, settings stay when a file is
/// watched to the end.
public final class FileSettingsStore {
    public static let shared = FileSettingsStore()

    /// Far more files than anyone adjusts by hand; the oldest go first.
    public static let capacity = 500

    private let store = FileRecordStore<FileSettings>(fileName: "file-settings.json",
                                                      capacity: FileSettingsStore.capacity)

    private init() {}

    /// The settings to apply when `url` is opened, or nil when there are none.
    public func settings(for url: URL) -> FileSettings? {
        store.checkedRecord(for: url)
    }

    /// Changes the settings for `url`, creating them if needed; settings left
    /// with nothing in them are dropped.
    public func update(_ url: URL, _ change: (inout FileSettings) -> Void) {
        var settings = store.record(for: url)
            ?? FileSettings(path: url.path, fileSize: store.fileSize(of: url), updatedAt: Date())
        let original = settings
        change(&settings)
        guard settings != original else { return }
        store.set(settings.isEmpty ? nil : settings, for: url)
    }
}
