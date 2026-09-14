import SwiftUI

/// What the on-screen display is currently reporting. Values are read live
/// from the player when drawn, so a burst of key presses always shows the
/// final value rather than the one at the time of the press.
public enum OSDItem: Equatable {
    case speed
    case volume
    case seek(seconds: Double)
    case replayLine
    case previousLine
    case nextLine
    case delay(MPVPlayer.DelayStream)
    case zoom
    case fill
    case crop(MPVPlayer.CropResult)
    case boostDialogue
    case translationMode
    case autoPause
    case loop
}

/// Keyboard feedback shown in the top-left corner for a moment, so the user
/// sees what a shortcut did even while the controls bar is hidden.
public final class OSDController: ObservableObject {
    public static let shared = OSDController()

    @Published public private(set) var item: OSDItem?
    private var hideWorkItem: DispatchWorkItem?
    private let displayDuration: TimeInterval = 1.5

    public func show(_ item: OSDItem) {
        hideWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            self.item = item
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.25)) {
                self?.item = nil
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: work)
    }
}

public struct OSDView: View {
    @ObservedObject var osd = OSDController.shared
    @ObservedObject var player = MPVPlayer.shared

    public init() {}

    public var body: some View {
        VStack {
            HStack {
                if let item = osd.item {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: item))
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)
                        Text(text(for: item))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
            }
            Spacer()
        }
        .padding(20)
        .allowsHitTesting(false)
    }

    private func icon(for item: OSDItem) -> String {
        switch item {
        case .speed: return "gauge.with.needle"
        case .volume: return player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .seek(let s): return s < 0 ? "gobackward.5" : "goforward.5"
        case .replayLine: return "arrow.counterclockwise"
        case .previousLine: return "backward.end.alt.fill"
        case .nextLine: return "forward.end.alt.fill"
        case .delay(.audio): return "speaker.wave.2.fill"
        case .delay: return "captions.bubble.fill"
        case .zoom: return "plus.magnifyingglass"
        case .fill: return player.fillsWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        case .crop: return "crop"
        case .boostDialogue: return player.boostDialogue ? "waveform.badge.plus" : "waveform"
        case .translationMode:
            if player.translationMode == .always && player.translationUnavailableReason != nil {
                return "exclamationmark.bubble"
            }
            return player.translationMode == .always ? "captions.bubble.fill" : "captions.bubble"
        case .autoPause: return player.autoPauseAfterLine ? "pause.circle.fill" : "pause.circle"
        case .loop: return player.loopMode == .off ? "repeat" : "repeat.circle.fill"
        }
    }

    private func text(for item: OSDItem) -> String {
        switch item {
        case .speed:
            return String(localized: "Speed \(Self.speedLabel(player.playbackSpeed))")
        case .volume:
            return player.isMuted ? String(localized: "Muted") : String(localized: "Volume \(Int(player.volume.rounded()))%")
        case .seek(let s):
            let sign = s < 0 ? "−" : "+"
            return String(localized: "\(sign)\(Int(abs(s))) s  ·  \(Self.formatTime(player.currentTime))")
        case .replayLine:
            return String(localized: "Replay line")
        case .previousLine:
            return String(localized: "Previous line")
        case .nextLine:
            return String(localized: "Next line")
        case .delay(let stream):
            let value = Self.delayLabel(player.delay(of: stream))
            switch stream {
            case .subtitle: return String(localized: "Subtitle delay \(value)")
            case .secondarySubtitle: return String(localized: "Translation delay \(value)")
            case .audio: return String(localized: "Audio delay \(value)")
            }
        case .zoom:
            var text = String(localized: "Zoom \(Int((player.zoomScale * 100).rounded()))%")
            let offset = Self.panLabel(x: player.videoPanX, y: player.videoPanY)
            if !offset.isEmpty {
                text += "  ·  " + offset
            }
            return text
        case .fill:
            return player.fillsWindow ? String(localized: "Fill window") : String(localized: "Fit to window")
        case .crop(let result):
            switch result {
            case .cropped: return String(localized: "Black bars removed")
            case .nothingToCrop: return String(localized: "No black bars found")
            case .failed: return String(localized: "Could not measure this frame")
            }
        case .boostDialogue:
            return player.boostDialogue ? String(localized: "Boost dialogue on") : String(localized: "Boost dialogue off")
        case .translationMode:
            // Pinning the translation with no track to show would look broken;
            // say why instead of confirming the mode.
            if player.translationMode == .always, let reason = player.translationUnavailableReason {
                return SubtitlesLayer.unavailableMessage(for: reason)
            }
            return player.translationMode == .always
                ? String(localized: "Translation always shown")
                : String(localized: "Translation shown while TAB is held")
        case .autoPause:
            return player.autoPauseAfterLine
                ? String(localized: "Pause after each line on")
                : String(localized: "Pause after each line off")
        case .loop:
            switch player.loopMode {
            case .off: return String(localized: "Loop off")
            case .line: return String(localized: "Repeating this line")
            case .ab(let a, nil): return String(localized: "Loop start \(Self.formatTime(a)) — press ⇧L at the end")
            case .ab(let a, let b?): return String(localized: "Loop \(Self.formatTime(a)) – \(Self.formatTime(b))")
            }
        }
    }

    /// "→ 4%  ↓ 2%" for a non-centred picture, empty when centred.
    static func panLabel(x: Double, y: Double) -> String {
        var parts: [String] = []
        let px = Int((abs(x) * 100).rounded()), py = Int((abs(y) * 100).rounded())
        if px > 0 { parts.append((x > 0 ? "→ " : "← ") + "\(px)%") }
        if py > 0 { parts.append((y > 0 ? "↓ " : "↑ ") + "\(py)%") }
        return parts.joined(separator: "  ")
    }

    /// "+0.3 s", "−1.5 s" or "0 s"; the minus is typographic to match the seek OSD.
    static func delayLabel(_ seconds: Double) -> String {
        let rounded = (seconds * 100).rounded() / 100
        if rounded == 0 { return "0 s" }
        var text = String(format: "%.2f", abs(rounded))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (rounded < 0 ? "−" : "+") + text + " s"
    }

    static func speedLabel(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
