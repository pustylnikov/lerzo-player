import Foundation
import AppKit

/// Something remembered about one file, keyed by its path.
protocol FileRecord: Codable, Equatable {
    var path: String { get }
    /// Tells a re-encoded file with the same name from the one the record
    /// belongs to; nil when the size could not be read.
    var fileSize: Int64? { get }
    var updatedAt: Date { get set }
}

/// At most one record per file, kept as a JSON array in Application Support
/// next to the cards. Mutations happen on the main thread; writes are
/// debounced, run off it and are flushed on quit.
final class FileRecordStore<Record: FileRecord> {
    let fileURL: URL
    private let capacity: Int
    private var records: [String: Record]
    private let fileQueue: DispatchQueue
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private let saveDelay: TimeInterval = 0.35

    /// Beyond `capacity` records the oldest go first.
    init(fileName: String, capacity: Int) {
        self.capacity = capacity
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first!
        let directoryURL = applicationSupport.appendingPathComponent("Lerzo Player", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent(fileName)
        fileQueue = DispatchQueue(label: "com.lerzo.player.\(fileName)", qos: .utility)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        records = Dictionary(Self.load(from: fileURL).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveImmediately()
        }
    }

    /// The record for `url` as stored, for updating it.
    func record(for url: URL) -> Record? {
        records[url.path]
    }

    /// The record for `url` when the file is opened, or nil when there is
    /// none or it belonged to a different file under the same name.
    func checkedRecord(for url: URL) -> Record? {
        guard let record = records[url.path] else { return nil }
        if let size = record.fileSize, let current = fileSize(of: url), size != current {
            // A different file under the old name: nothing in the record applies.
            set(nil, for: url)
            return nil
        }
        return record
    }

    /// Stores `record` as the newest one for `url`; nil removes it.
    func set(_ record: Record?, for url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var record else {
            guard records.removeValue(forKey: url.path) != nil else { return }
            scheduleSave()
            return
        }
        record.updatedAt = Date()
        records[url.path] = record
        trim()
        scheduleSave()
    }

    func saveImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = sortedRecords
        fileQueue.sync { Self.write(snapshot, to: fileURL) }
    }

    func fileSize(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private func trim() {
        guard records.count > capacity else { return }
        for stale in sortedRecords.dropFirst(capacity) {
            records.removeValue(forKey: stale.path)
        }
    }

    /// Newest first, so the file reads naturally and trimming drops the tail.
    private var sortedRecords: [Record] {
        records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = sortedRecords
        let url = fileURL
        let work = DispatchWorkItem { Self.write(snapshot, to: url) }
        pendingSave = work
        fileQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private static func load(from url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Record].self, from: data)
        } catch {
            NSLog("Lerzo Player: could not read %@: %@", url.lastPathComponent, error.localizedDescription)
            return []
        }
    }

    private static func write(_ records: [Record], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Lerzo Player: could not save %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }
}
