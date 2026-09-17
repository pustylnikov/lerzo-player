import Foundation
import CoreGraphics
import Cmpv

/// Frames for the seek bar's hover preview.
///
/// A second, headless libmpv instance (`vo=null`, no audio, no subtitles)
/// opens the same file and seeks there instead of the player, so the picture
/// on screen never moves while the pointer wanders along the bar. It decodes
/// in software: for one frame per seek the hardware decoder's session setup
/// costs more than it saves. A `scale` filter shrinks frames to preview size
/// before `screenshot-raw` copies them out; an HDR frame comes out in 16 bits
/// and is tone-mapped to sRGB here (`HDRThumbnail`). swscale could do that,
/// but mpv rebuilds the filter graph on every seek and swscale then spends
/// 300–500 ms on its colour LUT each time.
///
/// Requests coalesce: the worker always takes the newest position, showing
/// the nearest keyframe (tens of milliseconds) while the pointer sweeps and
/// the exact frame once it rests. The instance is torn down after
/// a while without requests so an idle player holds no second decoder.
public final class FramePreviewer: ObservableObject {
    public static let shared = FramePreviewer()

    public struct Preview {
        public let url: URL
        /// Where the frame actually is; behind the request for a keyframe.
        public let time: Double
        public let exact: Bool
        /// Nil when no frame could be taken (a file without video, a
        /// decoder failure): the card goes dark rather than keeping the
        /// frame of an earlier position.
        public let image: CGImage?
        /// Display aspect of the source, for the box the image is drawn in.
        public let aspect: Double
    }

    @Published public private(set) var preview: Preview?

    /// Preview frames are decoded at twice this box for Retina displays.
    public static let boxSize = CGSize(width: 240, height: 160)
    private static let idleTimeout: TimeInterval = 20

    private let condition = NSCondition()
    private var pending: (url: URL, time: Double, referenceHDR: Bool)?
    private var thread: Thread?

    // Worker-thread state.
    private var mpv: OpaquePointer?
    private var loadedURL: URL?

    private init() {}

    /// Forgets the last frame, so a later hover starts from a dark card
    /// instead of a frame from wherever the pointer was before.
    public func clear() {
        preview = nil
    }

    /// Asks for the frame at `time` of `url`; an earlier request still
    /// waiting is replaced.
    public func request(url: URL, time: Double, referenceHDR: Bool) {
        condition.lock()
        pending = (url, time, referenceHDR)
        if thread == nil {
            let worker = Thread { [self] in run() }
            worker.name = "LerzoPlayer.FramePreviewer"
            thread = worker
            worker.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            var timedOut = false
            while pending == nil && !timedOut {
                if mpv == nil {
                    condition.wait()
                } else {
                    timedOut = !condition.wait(until: Date(timeIntervalSinceNow: Self.idleTimeout))
                }
            }
            let job = pending
            pending = nil
            condition.unlock()

            guard let job else {
                destroy()
                continue
            }
            guard let handle = ensureHandle(), load(job.url, into: handle) else { continue }

            // The keyframe is a stand-in while the pointer sweeps: a frame
            // from seconds earlier, often another shot. Once the pointer
            // rests it would only flash before the exact frame replaces it,
            // so then only the exact one is shown.
            seek(handle, to: job.time, exact: false)
            condition.lock()
            let sweeping = pending != nil
            condition.unlock()
            if sweeping {
                publish(handle, url: job.url, exact: false, referenceHDR: job.referenceHDR)
            } else {
                seek(handle, to: job.time, exact: true)
                publish(handle, url: job.url, exact: true, referenceHDR: job.referenceHDR)
            }
        }
    }

    private func ensureHandle() -> OpaquePointer? {
        if let mpv { return mpv }
        guard let handle = mpv_create() else { return nil }
        mpv_set_option_string(handle, "vo", "null")
        mpv_set_option_string(handle, "ao", "null")
        mpv_set_option_string(handle, "aid", "no")
        mpv_set_option_string(handle, "sid", "no")
        mpv_set_option_string(handle, "hwdec", "no")
        mpv_set_option_string(handle, "pause", "yes")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "cache", "no")
        mpv_set_option_string(handle, "demuxer-max-bytes", "16MiB")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        let w = Int(Self.boxSize.width * 2), h = Int(Self.boxSize.height * 2)
        mpv_set_option_string(handle, "vf", "scale=w=\(w):h=\(h):force_original_aspect_ratio=decrease:force_divisible_by=2")
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return nil
        }
        mpv = handle
        return handle
    }

    private func destroy() {
        if let handle = mpv {
            mpv_terminate_destroy(handle)
        }
        mpv = nil
        loadedURL = nil
    }

    private func load(_ url: URL, into handle: OpaquePointer) -> Bool {
        if loadedURL == url { return true }
        loadedURL = nil
        drainEvents(handle)
        command(handle, ["loadfile", url.path, "replace"])
        // The first frame follows the load; waiting for it keeps that
        // restart from being mistaken for the one of the first seek.
        guard waitFor(MPV_EVENT_FILE_LOADED, on: handle, timeout: 15),
              waitFor(MPV_EVENT_PLAYBACK_RESTART, on: handle, timeout: 15) else { return false }
        loadedURL = url
        return true
    }

    private func seek(_ handle: OpaquePointer, to time: Double, exact: Bool) {
        drainEvents(handle)
        command(handle, ["seek", "\(max(0, time))", exact ? "absolute+exact" : "absolute+keyframes"])
        _ = waitFor(MPV_EVENT_PLAYBACK_RESTART, on: handle, timeout: 3)
    }

    private func publish(_ handle: OpaquePointer, url: URL, exact: Bool, referenceHDR: Bool) {
        let maxDimension = Int(max(Self.boxSize.width, Self.boxSize.height) * 2)
        let frame: MPVPlayer.RawFrame?
        let image: CGImage?
        if let transfer = HDRThumbnail.Transfer(mpv: property(handle, "video-params/gamma")) {
            var peak = 0.0
            mpv_get_property(handle, "video-params/max-luma", MPV_FORMAT_DOUBLE, &peak)
            let wideGamut = property(handle, "video-params/primaries") == "bt.2020"
            frame = MPVPlayer.grabRawFrame(handle, format: "rgba64")
            image = frame.flatMap {
                HDRThumbnail.sdrImage(from: $0, transfer: transfer, peakNits: peak,
                                      wideGamut: wideGamut, dimmed: referenceHDR)
            }
        } else {
            frame = MPVPlayer.grabRawFrame(handle)
            image = frame.flatMap { MPVPlayer.cgImage(from: $0, maxDimension: maxDimension) }
        }
        var time = 0.0, aspect = 0.0
        mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &time)
        mpv_get_property(handle, "video-params/aspect", MPV_FORMAT_DOUBLE, &aspect)
        if aspect <= 0, let frame { aspect = Double(frame.width) / Double(frame.height) }
        if aspect <= 0 { aspect = 16 / 9 }
        let preview = Preview(url: url, time: time, exact: exact, image: image, aspect: aspect)
        DispatchQueue.main.async { self.preview = preview }
    }

    // MARK: - libmpv plumbing

    private func property(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    private func command(_ handle: OpaquePointer, _ args: [String]) {
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        defer { for ptr in cArgs where ptr != nil { free(UnsafeMutableRawPointer(mutating: ptr)) } }
        mpv_command(handle, &cArgs)
    }

    /// Leftovers from earlier commands must not satisfy the next wait.
    private func drainEvents(_ handle: OpaquePointer) {
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
    }

    /// False when the file ends (or fails) first, or on timeout.
    private func waitFor(_ id: mpv_event_id, on handle: OpaquePointer, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.1) else { return false }
            switch event.pointee.event_id {
            case id: return true
            case MPV_EVENT_END_FILE:
                // `loadfile … replace` first ends the file playing before,
                // which is not the new one failing to load.
                let reason = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                if id == MPV_EVENT_FILE_LOADED && reason != MPV_END_FILE_REASON_ERROR { continue }
                loadedURL = nil
                return false
            default: continue
            }
        }
        return false
    }
}

/// HDR → SDR for a preview frame, the way mpv shows HDR on an SDR display
/// by default: PQ or HLG to display light, BT.2390 EETF on luminance
/// towards a 203-nit white, BT.2020 → BT.709 with clipping, sRGB out.
enum HDRThumbnail {
    enum Transfer {
        case pq, hlg
        init?(mpv name: String?) {
            switch name {
            case "pq": self = .pq
            case "hlg": self = .hlg
            default: return nil
            }
        }
    }

    /// SDR white in nits; both mpv and macOS map it to sRGB white.
    private static let referenceWhite = 203.0

    static func sdrImage(from frame: MPVPlayer.RawFrame, transfer: Transfer, peakNits: Double,
                         wideGamut: Bool, dimmed: Bool) -> CGImage? {
        guard frame.format == "rgba64" else { return nil }
        let toNits = transfer == .pq ? pqEOTF : hlgEOTF
        // Without usable mastering metadata assume the common 1000-nit grade.
        let peak = peakNits > referenceWhite ? peakNits : 1000
        let curve = BT2390(peakNits: peak, targetNits: referenceWhite)
        let width = frame.width, height = frame.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        frame.pixels.withUnsafeBytes { raw in
            for y in 0..<height {
                let row = raw.baseAddress!.advanced(by: y * frame.stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let r = toNits[Int(row[x * 4])], g = toNits[Int(row[x * 4 + 1])], b = toNits[Int(row[x * 4 + 2])]
                    // Luminance-preserving: one gain for all three channels.
                    let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
                    let gain = luma > 0 ? curve.map(luma) / luma : 0
                    var (r1, g1, b1) = (r * gain / referenceWhite, g * gain / referenceWhite, b * gain / referenceWhite)
                    if wideGamut {
                        (r1, g1, b1) = (1.6605 * r1 - 0.5876 * g1 - 0.0728 * b1,
                                        -0.1246 * r1 + 1.1329 * g1 - 0.0083 * b1,
                                        -0.0182 * r1 - 0.1006 * g1 + 1.1187 * b1)
                    }
                    let i = (y * width + x) * 4
                    rgba[i] = encode(r1, dimmed: dimmed)
                    rgba[i + 1] = encode(g1, dimmed: dimmed)
                    rgba[i + 2] = encode(b1, dimmed: dimmed)
                }
            }
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Linear → sRGB 8-bit. `dimmed` reproduces the accurate HDR mode's
    /// look, where absolute PQ luminance leaves the picture short of sRGB
    /// white: highlights are compressed and shadows lifted a little.
    private static func encode(_ value: Double, dimmed: Bool) -> UInt8 {
        let v = min(max(value, 0), 1)
        var srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        if dimmed { srgb = srgb * 0.82 + 8.0 / 255 }
        return UInt8((min(max(srgb, 0), 1) * 255).rounded())
    }

    // MARK: Transfer functions (16-bit code → nits)

    private static let pqEOTF: [Double] = (0...65535).map { code in
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let e = pow(Double(code) / 65535, 1 / m2)
        return 10000 * pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1)
    }

    /// HLG inverse OETF per channel, then the BT.2100 OOTF gamma applied
    /// per channel rather than on luminance (close enough for a thumbnail),
    /// for the nominal 1000-nit display.
    private static let hlgEOTF: [Double] = (0...65535).map { code in
        let e = Double(code) / 65535
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let scene = e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
        return 1000 * pow(scene, 1.2)
    }

    private static func pqOETF(_ nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(max(nits, 0) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private static func pqToNits(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(e, 0), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// BT.2390 EETF: luminance in nits → luminance in nits, identity up to
    /// the knee and a Hermite roll-off from there to the target peak.
    private struct BT2390 {
        let maxSource: Double, maxTarget: Double, knee: Double

        init(peakNits: Double, targetNits: Double) {
            maxSource = pqOETF(peakNits)
            maxTarget = pqOETF(targetNits) / maxSource
            knee = 1.5 * maxTarget - 0.5
        }

        func map(_ nits: Double) -> Double {
            let e = pqOETF(nits) / maxSource
            guard e > knee, knee < 1 else { return nits }
            let t = (e - knee) / (1 - knee)
            let t2 = t * t, t3 = t2 * t
            let p = (2 * t3 - 3 * t2 + 1) * knee + (t3 - 2 * t2 + t) * (1 - knee) + (-2 * t3 + 3 * t2) * maxTarget
            return pqToNits(p * maxSource)
        }
    }
}
