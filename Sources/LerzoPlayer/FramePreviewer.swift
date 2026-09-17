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
/// before `screenshot-raw` copies them out.
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
        public let image: CGImage
        /// Display aspect of the source, for the box the image is drawn in.
        public let aspect: Double
    }

    @Published public private(set) var preview: Preview?

    /// Preview frames are decoded at twice this box for Retina displays.
    public static let boxSize = CGSize(width: 240, height: 160)
    private static let idleTimeout: TimeInterval = 20

    private let condition = NSCondition()
    private var pending: (url: URL, time: Double)?
    private var thread: Thread?

    // Worker-thread state.
    private var mpv: OpaquePointer?
    private var loadedURL: URL?

    private init() {}

    /// Asks for the frame at `time` of `url`; an earlier request still
    /// waiting is replaced.
    public func request(url: URL, time: Double) {
        condition.lock()
        pending = (url, time)
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
                publish(handle, url: job.url, exact: false)
            } else {
                seek(handle, to: job.time, exact: true)
                publish(handle, url: job.url, exact: true)
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

    private func publish(_ handle: OpaquePointer, url: URL, exact: Bool) {
        guard let frame = MPVPlayer.grabRawFrame(handle),
              let image = MPVPlayer.cgImage(from: frame, maxDimension: Int(max(Self.boxSize.width, Self.boxSize.height) * 2)) else { return }
        var time = 0.0, aspect = 0.0
        mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &time)
        mpv_get_property(handle, "video-params/aspect", MPV_FORMAT_DOUBLE, &aspect)
        if aspect <= 0 { aspect = Double(frame.width) / Double(frame.height) }
        let preview = Preview(url: url, time: time, exact: exact, image: image, aspect: aspect)
        DispatchQueue.main.async { self.preview = preview }
    }

    // MARK: - libmpv plumbing

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
