import Foundation
import Combine

/// Where playback stopped in a file that was not watched to the end.
public struct PlaybackPosition: FileRecord {
    public let path: String
    public var position: Double
    public var duration: Double
    /// Tells a re-encoded file with the same name from the one the position
    /// belongs to; nil when the size could not be read.
    public var fileSize: Int64?
    public var updatedAt: Date
}

/// Remembers where each unfinished file was stopped so it can reopen there.
///
/// Positions live in `playback-positions.json`; the format stays as it is so
/// that earlier versions keep reading it (per-file settings have their own
/// file, see `FileSettingsStore`).
public final class PlaybackHistory: ObservableObject {
    public static let shared = PlaybackHistory()

    /// Whether reopening a file seeks to the remembered position. The
    /// positions are recorded either way, so switching the setting back on
    /// does not start from an empty history.
    @Published public var resumesPlayback: Bool {
        didSet { UserDefaults.standard.set(resumesPlayback, forKey: Self.resumesPlaybackKey) }
    }
    private static let resumesPlaybackKey = "LerzoPlayer.resumePlayback"

    /// Far more than anyone has unfinished files at once (finished ones are
    /// dropped), and still a small file; the oldest go first.
    public static let capacity = 500
    /// Below this there is nothing worth coming back to.
    public static let minimumPosition: Double = 10
    /// Watched this far, the file counts as finished (long credits included),
    /// so it starts from the beginning next time rather than at the credits.
    public static let finishedFraction = 0.95
    public static let finishedTail: Double = 30

    private let store = FileRecordStore<PlaybackPosition>(fileName: "playback-positions.json",
                                                          capacity: PlaybackHistory.capacity)

    private init() {
        let defaults = UserDefaults.standard
        resumesPlayback = defaults.object(forKey: Self.resumesPlaybackKey) == nil
            || defaults.bool(forKey: Self.resumesPlaybackKey)
    }

    /// The position to reopen `url` at, or nil to start from the beginning.
    public func resumePosition(for url: URL) -> Double? {
        guard resumesPlayback else { return nil }
        return store.checkedRecord(for: url)?.position
    }

    /// Records where `url` stopped. Barely started and finished files are
    /// dropped instead, so they start from the beginning next time.
    public func record(url: URL, position: Double, duration: Double) {
        guard duration > 0 else { return }
        let started = position >= Self.minimumPosition
        let finished = duration - position < Self.finishedTail
            || position / duration >= Self.finishedFraction
        guard started, !finished else {
            forget(url)
            return
        }
        var entry = store.record(for: url)
            ?? PlaybackPosition(path: url.path, position: position, duration: duration,
                                fileSize: store.fileSize(of: url), updatedAt: Date())
        entry.position = position
        entry.duration = duration
        store.set(entry, for: url)
    }

    public func forget(_ url: URL) {
        store.set(nil, for: url)
    }

    public func saveImmediately() {
        store.saveImmediately()
    }
}
