import Foundation

/// Pulls one subtitle track's blocks out of a Matroska file without reading
/// the video and audio around them.
///
/// libavformat's demuxer reads the payload of every block, even for streams
/// it was told to discard, so collecting the subtitles of a 20 GB remux means
/// reading 20 GB. Both mkvmerge and ffmpeg index every subtitle block in the
/// Cues element, so normally only the index and the subtitle blocks
/// themselves are read: a few hundred kilobytes. Files whose index lacks the
/// track fall back to walking the clusters and `pread`-ing block headers.
enum MatroskaSubtitleScanner {
    struct Block {
        let start: Double
        let duration: Double
        let data: Data
    }

    /// Reads the `subtitleOrdinal`-th subtitle track (0-based, in TrackEntry
    /// order, which is also the order libavformat numbers its streams in),
    /// provided its CodecID is one of `codecIDs`. Returns `nil` on anything
    /// unexpected — a codec mismatch, a laced subtitle block, a truncated
    /// header — so the caller can fall back to the slow path rather than
    /// trust a partial or wrong list.
    static func scan(path: String, subtitleOrdinal: Int, codecIDs: Set<String>) -> [Block]? {
        guard let reader = Reader(path: path) else { return nil }
        defer { reader.close() }
        var state = ScanState(subtitleOrdinal: subtitleOrdinal, codecIDs: codecIDs)

        do {
            while let element = try reader.readElementHeader() {
                switch element.id {
                case .segment:
                    let end = element.knownEnd ?? reader.fileSize
                    try scanSegment(reader, element: element, end: end, state: &state)
                default:
                    try reader.skip(element)
                }
            }
        } catch {
            return nil
        }
        return state.trackNumber != nil ? state.blocks : nil
    }

    private struct ScanState {
        let subtitleOrdinal: Int
        let codecIDs: Set<String>
        var timestampScale: UInt64 = 1_000_000
        /// Set once the Tracks element identified the wanted track.
        var trackNumber: UInt64?
        /// Absolute file offset of the Cues element, from SeekHead or from
        /// meeting it before the first cluster.
        var cuesPosition: UInt64?
        var blocks: [Block] = []
    }

    private static func scanSegment(_ reader: Reader, element segment: Element, end: UInt64,
                                    state: inout ScanState) throws {
        var usedIndex = false
        while reader.position < end {
            let elementStart = reader.position
            guard let element = try reader.readElementHeader() else { break }
            switch element.id {
            case .info:
                let infoEnd = try element.requireKnownEnd()
                while reader.position < infoEnd, let child = try reader.readElementHeader() {
                    if child.id == .timestampScale {
                        state.timestampScale = try reader.readUnsigned(child)
                    } else {
                        try reader.skip(child)
                    }
                }
            case .seekHead:
                if let position = try findCuesPosition(reader, element: element, segmentStart: segment.dataStart) {
                    state.cuesPosition = position
                }
            case .cues:
                state.cuesPosition = elementStart
                try reader.skip(element)
            case .tracks where state.trackNumber == nil:
                state.trackNumber = try findTrack(reader, element: element,
                                                  subtitleOrdinal: state.subtitleOrdinal, codecIDs: state.codecIDs)
            case .cluster:
                // Clusters before Tracks would mean an unfamiliar layout.
                guard let trackNumber = state.trackNumber else { throw ScanError.malformed }
                if !usedIndex, let cuesPosition = state.cuesPosition {
                    usedIndex = true
                    let resume = reader.position
                    if try readIndexedBlocks(reader, cuesPosition: cuesPosition, segmentStart: segment.dataStart,
                                             trackNumber: trackNumber, scale: state.timestampScale, into: &state.blocks) {
                        return
                    }
                    reader.seek(to: resume)
                }
                try scanCluster(reader, element: element, trackNumber: trackNumber,
                                timestampScale: state.timestampScale, blocks: &state.blocks)
            default:
                try reader.skip(element)
            }
        }
    }

    /// TrackNumber of the wanted subtitle TrackEntry; throws when it is
    /// missing or its CodecID is not what libavformat reported.
    private static func findTrack(_ reader: Reader, element: Element,
                                  subtitleOrdinal: Int, codecIDs: Set<String>) throws -> UInt64 {
        let end = try element.requireKnownEnd()
        var subtitlesSeen = 0
        while reader.position < end, let entry = try reader.readElementHeader() {
            guard entry.id == .trackEntry else { try reader.skip(entry); continue }
            let entryEnd = try entry.requireKnownEnd()
            var number: UInt64?, type: UInt64?, codecID = ""
            while reader.position < entryEnd, let field = try reader.readElementHeader() {
                switch field.id {
                case .trackNumber: number = try reader.readUnsigned(field)
                case .trackType: type = try reader.readUnsigned(field)
                case .codecID:
                    let size = try field.requireKnownEnd() - field.dataStart
                    codecID = String(decoding: try reader.readBytes(count: Int(size)), as: UTF8.self)
                default: try reader.skip(field)
                }
            }
            guard type == 0x11 else { continue }   // 0x11 = subtitle track
            if subtitlesSeen == subtitleOrdinal {
                guard let number, codecIDs.contains(codecID) else { throw ScanError.malformed }
                return number
            }
            subtitlesSeen += 1
        }
        throw ScanError.malformed
    }

    // MARK: - Cues (index) path

    private static func findCuesPosition(_ reader: Reader, element: Element, segmentStart: UInt64) throws -> UInt64? {
        let end = try element.requireKnownEnd()
        var result: UInt64?
        while reader.position < end, let seek = try reader.readElementHeader() {
            guard seek.id == .seek else { try reader.skip(seek); continue }
            let seekEnd = try seek.requireKnownEnd()
            var id: UInt64?, position: UInt64?
            while reader.position < seekEnd, let field = try reader.readElementHeader() {
                switch field.id {
                case .seekID: id = try reader.readUnsigned(field)
                case .seekPosition: position = try reader.readUnsigned(field)
                default: try reader.skip(field)
                }
            }
            if id == UInt64(ElementID.cues.raw), let position {
                result = segmentStart + position
            }
        }
        return result
    }

    private struct CueEntry {
        let time: UInt64
        let clusterPosition: UInt64
        let relativePosition: UInt64?
    }

    /// Reads the wanted track's blocks through the Cues index. Returns
    /// `false` when the index has no entries for the track, so the caller can
    /// walk the clusters instead.
    private static func readIndexedBlocks(_ reader: Reader, cuesPosition: UInt64, segmentStart: UInt64,
                                          trackNumber: UInt64, scale: UInt64, into blocks: inout [Block]) throws -> Bool {
        reader.seek(to: cuesPosition)
        guard let cues = try reader.readElementHeader(), cues.id == .cues else { throw ScanError.malformed }
        let end = try cues.requireKnownEnd()
        var entries: [CueEntry] = []
        while reader.position < end, let point = try reader.readElementHeader() {
            guard point.id == .cuePoint else { try reader.skip(point); continue }
            let pointEnd = try point.requireKnownEnd()
            var time: UInt64?
            var positions: [(track: UInt64?, cluster: UInt64?, relative: UInt64?)] = []
            while reader.position < pointEnd, let field = try reader.readElementHeader() {
                switch field.id {
                case .cueTime:
                    time = try reader.readUnsigned(field)
                case .cueTrackPositions:
                    let fieldEnd = try field.requireKnownEnd()
                    var track: UInt64?, cluster: UInt64?, relative: UInt64?
                    while reader.position < fieldEnd, let sub = try reader.readElementHeader() {
                        switch sub.id {
                        case .cueTrack: track = try reader.readUnsigned(sub)
                        case .cueClusterPosition: cluster = try reader.readUnsigned(sub)
                        case .cueRelativePosition: relative = try reader.readUnsigned(sub)
                        default: try reader.skip(sub)
                        }
                    }
                    positions.append((track, cluster, relative))
                default:
                    try reader.skip(field)
                }
            }
            guard let time else { continue }
            for position in positions where position.track == trackNumber {
                guard let cluster = position.cluster else { continue }
                entries.append(CueEntry(time: time, clusterPosition: cluster, relativePosition: position.relative))
            }
        }
        guard !entries.isEmpty else { return false }

        var scannedClusters: Set<UInt64> = []
        for entry in entries {
            reader.seek(to: segmentStart + entry.clusterPosition)
            guard let cluster = try reader.readElementHeader(), cluster.id == .cluster else { throw ScanError.malformed }
            guard let relative = entry.relativePosition else {
                // No block offset: walk this cluster once, it computes exact times itself.
                if scannedClusters.insert(entry.clusterPosition).inserted {
                    try scanCluster(reader, element: cluster, trackNumber: trackNumber,
                                    timestampScale: scale, blocks: &blocks)
                }
                continue
            }
            reader.seek(to: cluster.dataStart + relative)
            guard let element = try reader.readElementHeader() else { throw ScanError.malformed }
            let payload: (data: Data, duration: UInt64)?
            switch element.id {
            case .simpleBlock:
                payload = try readBlock(reader, element: element, trackNumber: trackNumber).map { ($0.data, 0) }
            case .blockGroup:
                payload = try readBlockGroup(reader, element: element, trackNumber: trackNumber).map { ($0.data, $0.duration) }
            default:
                throw ScanError.malformed
            }
            // The index must point at our track; anything else means we misread it.
            guard let payload else { throw ScanError.malformed }
            blocks.append(Block(start: Double(entry.time) * Double(scale) / 1e9,
                                duration: Double(payload.duration) * Double(scale) / 1e9,
                                data: payload.data))
        }
        return true
    }

    // MARK: - Cluster walk

    private static func scanCluster(_ reader: Reader, element: Element, trackNumber: UInt64,
                                    timestampScale: UInt64, blocks: inout [Block]) throws {
        let end = element.knownEnd ?? reader.fileSize
        var clusterTime: UInt64 = 0
        func append(_ relative: Int64, duration: UInt64, data: Data) {
            let ns = Double(Int64(clusterTime) + relative) * Double(timestampScale)
            blocks.append(Block(start: ns / 1e9, duration: Double(duration) * Double(timestampScale) / 1e9, data: data))
        }
        while reader.position < end {
            let childStart = reader.position
            guard let child = try reader.readElementHeader() else { break }
            switch child.id {
            case .timestamp:
                clusterTime = try reader.readUnsigned(child)
            case .simpleBlock:
                if let block = try readBlock(reader, element: child, trackNumber: trackNumber) {
                    append(block.relative, duration: 0, data: block.data)
                }
            case .blockGroup:
                if let group = try readBlockGroup(reader, element: child, trackNumber: trackNumber) {
                    append(group.relative, duration: group.duration, data: group.data)
                }
            default:
                if element.knownEnd == nil && child.id.isSegmentLevel {
                    // Unknown-sized cluster ends where the next top-level element begins.
                    reader.seek(to: childStart)
                    return
                }
                try reader.skip(child)
            }
        }
    }

    /// Reads a (Simple)Block header; returns the payload and the timestamp
    /// relative to the cluster when it belongs to the wanted track, otherwise
    /// skips it.
    private static func readBlock(_ reader: Reader, element: Element,
                                  trackNumber: UInt64) throws -> (relative: Int64, data: Data)? {
        let end = try element.requireKnownEnd()
        guard let track = try reader.readVInt(), track == trackNumber else {
            reader.seek(to: end)
            return nil
        }
        let relative = Int64(Int16(bitPattern: UInt16(try reader.readByte()) << 8 | UInt16(try reader.readByte())))
        let flags = try reader.readByte()
        guard flags & 0x06 == 0 else { throw ScanError.lacedSubtitle }
        guard reader.position <= end else { throw ScanError.malformed }
        let data = try reader.readBytes(count: Int(end - reader.position))
        return (relative, data)
    }

    /// A BlockGroup: the Block plus its BlockDuration, which usually follows it.
    private static func readBlockGroup(_ reader: Reader, element: Element,
                                       trackNumber: UInt64) throws -> (relative: Int64, duration: UInt64, data: Data)? {
        let end = try element.requireKnownEnd()
        var blockElement: Element?
        var duration: UInt64 = 0
        while reader.position < end, let member = try reader.readElementHeader() {
            switch member.id {
            case .block:
                blockElement = member
                try reader.skip(member)
            case .blockDuration:
                duration = try reader.readUnsigned(member)
            default:
                try reader.skip(member)
            }
        }
        guard let blockElement else { return nil }
        let resume = reader.position
        defer { reader.seek(to: resume) }
        reader.seek(to: blockElement.dataStart)
        guard let block = try readBlock(reader, element: blockElement, trackNumber: trackNumber) else { return nil }
        return (block.relative, duration, block.data)
    }

    // MARK: - EBML

    enum ScanError: Error {
        case malformed
        case lacedSubtitle
    }

    struct ElementID: Equatable {
        let raw: UInt32
        static let ebmlHeader = ElementID(raw: 0x1A45DFA3)
        static let segment = ElementID(raw: 0x18538067)
        static let seekHead = ElementID(raw: 0x114D9B74)
        static let seek = ElementID(raw: 0x4DBB)
        static let seekID = ElementID(raw: 0x53AB)
        static let seekPosition = ElementID(raw: 0x53AC)
        static let info = ElementID(raw: 0x1549A966)
        static let timestampScale = ElementID(raw: 0x2AD7B1)
        static let tracks = ElementID(raw: 0x1654AE6B)
        static let trackEntry = ElementID(raw: 0xAE)
        static let trackNumber = ElementID(raw: 0xD7)
        static let trackType = ElementID(raw: 0x83)
        static let codecID = ElementID(raw: 0x86)
        static let cluster = ElementID(raw: 0x1F43B675)
        static let cues = ElementID(raw: 0x1C53BB6B)
        static let cuePoint = ElementID(raw: 0xBB)
        static let cueTime = ElementID(raw: 0xB3)
        static let cueTrackPositions = ElementID(raw: 0xB7)
        static let cueTrack = ElementID(raw: 0xF7)
        static let cueClusterPosition = ElementID(raw: 0xF1)
        static let cueRelativePosition = ElementID(raw: 0xF0)
        static let attachments = ElementID(raw: 0x1941A469)
        static let chapters = ElementID(raw: 0x1043A770)
        static let tags = ElementID(raw: 0x1254C367)
        static let timestamp = ElementID(raw: 0xE7)
        static let simpleBlock = ElementID(raw: 0xA3)
        static let blockGroup = ElementID(raw: 0xA0)
        static let block = ElementID(raw: 0xA1)
        static let blockDuration = ElementID(raw: 0x9B)

        /// Direct children of Segment: seeing one of these ends an unknown-sized cluster.
        var isSegmentLevel: Bool {
            [Self.seekHead, .info, .tracks, .cluster, .cues, .attachments, .chapters, .tags].contains(self)
        }
    }

    struct Element {
        let id: ElementID
        let dataStart: UInt64
        /// `nil` for the "unknown size" marker (live-style Segments and Clusters).
        let size: UInt64?

        var knownEnd: UInt64? { size.map { dataStart + $0 } }

        func requireKnownEnd() throws -> UInt64 {
            guard let end = knownEnd else { throw ScanError.malformed }
            return end
        }
    }

    /// Buffered reader over a file descriptor; a seek past the buffer is
    /// just a position change, so the bulk of the file is never read.
    ///
    /// The buffer is deliberately small: on the cluster walk every video
    /// frame is skipped and the buffer refilled, and at 64 KB that added up
    /// to most of a 4K file again. 4 KB still covers the run of audio blocks
    /// between two frames.
    final class Reader {
        private let fd: Int32
        let fileSize: UInt64
        private(set) var position: UInt64 = 0
        private var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        private var bufferStart: UInt64 = 0
        private var bufferCount = 0

        init?(path: String) {
            fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); return nil }
            fileSize = UInt64(info.st_size)
            // Reads are scattered; kernel read-ahead would fetch the frames we skip.
            _ = fcntl(fd, F_RDAHEAD, 0)
        }

        func close() { Darwin.close(fd) }

        func seek(to offset: UInt64) { position = offset }

        func skip(_ element: Element) throws {
            position = try element.requireKnownEnd()
        }

        private func fill() throws -> Bool {
            let got = pread(fd, &buffer, buffer.count, off_t(position))
            guard got > 0 else { return false }
            bufferStart = position
            bufferCount = got
            return true
        }

        func readByte() throws -> UInt8 {
            if position < bufferStart || position >= bufferStart + UInt64(bufferCount) {
                guard try fill() else { throw ScanError.malformed }
            }
            let byte = buffer[Int(position - bufferStart)]
            position += 1
            return byte
        }

        func readBytes(count: Int) throws -> Data {
            var data = Data(count: count)
            var done = 0
            try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                while done < count {
                    let got = pread(fd, raw.baseAddress! + done, count - done, off_t(position) + off_t(done))
                    guard got > 0 else { throw ScanError.malformed }
                    done += got
                }
            }
            position += UInt64(count)
            return data
        }

        /// Element ID: 1–4 bytes, marker bit kept. `nil` at end of file.
        func readElementHeader() throws -> Element? {
            guard position < fileSize else { return nil }
            let first = try readByte()
            let length = first >= 0x80 ? 1 : first >= 0x40 ? 2 : first >= 0x20 ? 3 : first >= 0x10 ? 4 : 0
            guard length > 0 else { throw ScanError.malformed }
            var id = UInt32(first)
            for _ in 1..<length { id = id << 8 | UInt32(try readByte()) }
            let size = try readVInt()
            return Element(id: ElementID(raw: id), dataStart: position, size: size)
        }

        /// Variable-size integer, marker bit removed. `nil` means "unknown size".
        func readVInt() throws -> UInt64? {
            let first = try readByte()
            guard first != 0 else { throw ScanError.malformed }
            let length = first.leadingZeroBitCount + 1
            var value = UInt64(first & (0xFF >> length))
            var allOnes = value == (0xFF >> length)
            for _ in 1..<length {
                let byte = try readByte()
                allOnes = allOnes && byte == 0xFF
                value = value << 8 | UInt64(byte)
            }
            return allOnes ? nil : value
        }

        func readUnsigned(_ element: Element) throws -> UInt64 {
            let size = try element.requireKnownEnd() - element.dataStart
            guard size <= 8 else { throw ScanError.malformed }
            var value: UInt64 = 0
            for _ in 0..<size { value = value << 8 | UInt64(try readByte()) }
            return value
        }
    }
}
