import Foundation
import AppKit
import Combine

/// Where playback stopped in a file that was not watched to the end.
public struct PlaybackPosition: Codable, Equatable {
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
/// Positions live in `playback-positions.json` next to the cards. Mutations
/// happen on the main thread; writes are debounced and run off it.
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

    private static let saveDelay: TimeInterval = 0.35

    public let fileURL: URL
    private var entries: [String: PlaybackPosition]
    private let fileQueue = DispatchQueue(label: "com.lerzo.player.playback-history", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        resumesPlayback = defaults.object(forKey: Self.resumesPlaybackKey) == nil
            || defaults.bool(forKey: Self.resumesPlaybackKey)

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first!
        let directoryURL = applicationSupport.appendingPathComponent("Lerzo Player", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("playback-positions.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        entries = Dictionary(Self.load(from: fileURL).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveImmediately()
        }
    }

    /// The position to reopen `url` at, or nil to start from the beginning.
    public func resumePosition(for url: URL) -> Double? {
        guard resumesPlayback, let entry = entries[url.path] else { return nil }
        if let size = entry.fileSize, let current = Self.fileSize(of: url), size != current {
            // A different file under the old name: the position means nothing.
            forget(url)
            return nil
        }
        return entry.position
    }

    /// Records where `url` stopped. Barely started and finished files are
    /// dropped instead, so they start from the beginning next time.
    public func record(url: URL, position: Double, duration: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard duration > 0 else { return }
        let started = position >= Self.minimumPosition
        let finished = duration - position < Self.finishedTail
            || position / duration >= Self.finishedFraction
        guard started, !finished else {
            forget(url)
            return
        }
        let path = url.path
        var entry = entries[path] ?? PlaybackPosition(path: path, position: position, duration: duration,
                                                      fileSize: Self.fileSize(of: url), updatedAt: Date())
        entry.position = position
        entry.duration = duration
        entry.updatedAt = Date()
        entries[path] = entry
        trim()
        scheduleSave()
    }

    public func forget(_ url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard entries.removeValue(forKey: url.path) != nil else { return }
        scheduleSave()
    }

    public func saveImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = sortedEntries
        fileQueue.sync { Self.write(snapshot, to: fileURL) }
    }

    private func trim() {
        guard entries.count > Self.capacity else { return }
        for stale in sortedEntries.dropFirst(Self.capacity) {
            entries.removeValue(forKey: stale.path)
        }
    }

    /// Newest first, so the file reads naturally and trimming drops the tail.
    private var sortedEntries: [PlaybackPosition] {
        entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = sortedEntries
        let url = fileURL
        let work = DispatchWorkItem { Self.write(snapshot, to: url) }
        pendingSave = work
        fileQueue.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private static func fileSize(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private static func load(from url: URL) -> [PlaybackPosition] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PlaybackPosition].self, from: data)
        } catch {
            NSLog("Lerzo Player: could not read playback-positions.json: %@", error.localizedDescription)
            return []
        }
    }

    private static func write(_ entries: [PlaybackPosition], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Lerzo Player: could not save playback-positions.json: %@", error.localizedDescription)
        }
    }
}
