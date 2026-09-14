import Foundation
import Cavformat

/// One subtitle event. Times are in the subtitle's own clock, i.e. before
/// `sub-delay` is applied.
public struct SubtitleCue: Equatable {
    public let start: Double
    public let end: Double
    public let text: String
}

/// Every event of one subtitle track, read up front with libavformat.
///
/// mpv's `sub-seek` only knows the events its decoder has already been fed,
/// which for subtitles muxed into the video file is the ones shown so far plus
/// a small prefetch window: jumping several lines ahead, or one line ahead
/// while paused, silently does nothing. Reading the whole track ourselves
/// gives exact timestamps for "previous / replay / next line".
public final class SubtitleTimeline {
    public let cues: [SubtitleCue]

    /// A seek lands on the frame at or just before the requested time, so a
    /// position this close before a cue still counts as being inside it.
    static let landingTolerance = 0.1
    /// Events starting within this window are one line (ASS styling often
    /// splits a line into several simultaneous events).
    private static let mergeWindow = 0.05

    init(cues: [SubtitleCue]) {
        self.cues = cues
    }

    /// Index of the line at `time`: the last cue starting at or before it.
    public func currentIndex(at time: Double) -> Int? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time + Self.landingTolerance { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// Index of the line whose span contains `time` (start ≤ time < end),
    /// with no landing tolerance: for deciding whether a line is still on
    /// screen, where the tolerance would hand the last tenth of a second of
    /// one line to a tightly packed next one.
    public func index(containing time: Double) -> Int? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, time < cues[lo - 1].end else { return nil }
        return lo - 1
    }

    /// Index of the line `skip` lines away from the one at `time`
    /// (0 = the current line, mpv's `sub-seek` semantics). `nil` when there is
    /// nothing to jump to in that direction.
    public func seekTargetIndex(from time: Double, skip: Int) -> Int? {
        guard !cues.isEmpty else { return nil }
        let current = currentIndex(at: time)
        let target: Int
        if skip > 0 {
            target = (current ?? -1) + skip
        } else if let current {
            target = max(0, current + skip)
        } else {
            return nil
        }
        return cues.indices.contains(target) ? target : nil
    }

    /// Start time of the line `seekTargetIndex` picks.
    public func seekTarget(from time: Double, skip: Int) -> Double? {
        seekTargetIndex(from: time, skip: skip).map { cues[$0].start }
    }

    // MARK: - Loading

    private static let textCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_SUBRIP, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA, AV_CODEC_ID_TEXT,
        AV_CODEC_ID_MOV_TEXT, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_SRT,
    ]

    /// Reads stream `streamIndex` (libavformat's index, mpv's `ff-index`) of
    /// `path`. Returns `nil` for bitmap subtitles and anything unreadable.
    /// Sequentially scans the whole file, so call it off the main thread.
    public static func load(path: String, streamIndex: Int) -> SubtitleTimeline? {
        var format: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&format, path, nil, nil) >= 0, let ctx = format else { return nil }
        defer { avformat_close_input(&format) }

        let streamCount = Int(ctx.pointee.nb_streams)
        guard streamIndex >= 0, streamIndex < streamCount,
              let stream = ctx.pointee.streams[streamIndex],
              let par = stream.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
              textCodecs.contains(par.pointee.codec_id) else { return nil }
        let codec = par.pointee.codec_id

        var raw: [SubtitleCue] = []
        let container = ctx.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        if container == "matroska,webm",
           let blocks = MatroskaSubtitleScanner.scan(path: path,
                                                     subtitleOrdinal: subtitleOrdinal(ctx, of: streamIndex),
                                                     codecIDs: matroskaCodecIDs(for: codec)) {
            // Fast path: only the subtitle blocks are read from disk.
            for block in blocks {
                let text = subtitleText(block.data, codec: codec)
                raw.append(SubtitleCue(start: block.start, end: block.start + block.duration, text: text))
            }
        } else if !readPackets(ctx, streamIndex: streamIndex, codec: codec, into: &raw) {
            return nil
        }

        raw.sort { $0.start < $1.start }
        var cues: [SubtitleCue] = []
        for cue in raw {
            if let last = cues.last, cue.start - last.start < mergeWindow {
                let joined = [last.text, cue.text].filter { !$0.isEmpty }.joined(separator: "\n")
                cues[cues.count - 1] = SubtitleCue(start: last.start, end: max(last.end, cue.end), text: joined)
            } else {
                cues.append(cue)
            }
        }
        return SubtitleTimeline(cues: cues)
    }

    /// Position of `streamIndex` among the file's subtitle streams.
    private static func subtitleOrdinal(_ ctx: UnsafeMutablePointer<AVFormatContext>, of streamIndex: Int) -> Int {
        (0..<streamIndex).filter {
            ctx.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        }.count
    }

    /// Matroska CodecIDs that libavformat maps to `codec`.
    private static func matroskaCodecIDs(for codec: AVCodecID) -> Set<String> {
        switch codec {
        case AV_CODEC_ID_SUBRIP: return ["S_TEXT/UTF8"]
        case AV_CODEC_ID_ASS, AV_CODEC_ID_SSA: return ["S_TEXT/ASS", "S_TEXT/SSA"]
        case AV_CODEC_ID_WEBVTT: return ["S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS",
                                         "D_WEBVTT/DESCRIPTIONS", "D_WEBVTT/METADATA"]
        case AV_CODEC_ID_TEXT: return ["S_TEXT/ASCII"]
        default: return []
        }
    }

    /// Slow path: demuxes the whole file with libavformat, which reads every
    /// stream's data even when told to discard it.
    private static func readPackets(_ ctx: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int,
                                    codec: AVCodecID, into raw: inout [SubtitleCue]) -> Bool {
        let streamCount = Int(ctx.pointee.nb_streams)
        for i in 0..<streamCount where i != streamIndex {
            ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }
        guard let stream = ctx.pointee.streams[streamIndex] else { return false }
        let timeBase = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
        guard let packet = av_packet_alloc() else { return false }
        var mutablePacket: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&mutablePacket) }

        while av_read_frame(ctx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard Int(packet.pointee.stream_index) == streamIndex,
                  packet.pointee.pts != Int64.min else { continue }   // AV_NOPTS_VALUE
            let start = Double(packet.pointee.pts) * timeBase
            let duration = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * timeBase : 0
            let text = packetText(packet, codec: codec)
            raw.append(SubtitleCue(start: start, end: start + duration, text: text))
        }
        return true
    }

    private static func packetText(_ packet: UnsafeMutablePointer<AVPacket>, codec: AVCodecID) -> String {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return "" }
        return subtitleText(Data(bytes: data, count: Int(packet.pointee.size)), codec: codec)
    }

    private static func subtitleText(_ payload: Data, codec: AVCodecID) -> String {
        var bytes = payload
        if codec == AV_CODEC_ID_MOV_TEXT {
            // tx3g samples carry a big-endian 16-bit length before the text.
            bytes = bytes.count > 2 ? bytes.dropFirst(2) : Data()
        }
        guard var text = String(data: bytes, encoding: .utf8) else { return "" }
        if codec == AV_CODEC_ID_ASS || codec == AV_CODEC_ID_SSA {
            text = assDialogueText(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Text field of an ASS event ("ReadOrder,Layer,Style,Name,MarginL,
    /// MarginR,MarginV,Effect,Text"), with override tags stripped.
    private static func assDialogueText(_ line: String) -> String {
        var rest = Substring(line)
        for _ in 0..<8 {
            guard let comma = rest.firstIndex(of: ",") else { return "" }
            rest = rest[rest.index(after: comma)...]
        }
        var text = String(rest)
        while let open = text.firstIndex(of: "{"), let close = text[open...].firstIndex(of: "}") {
            text.removeSubrange(open...close)
        }
        return text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }
}
