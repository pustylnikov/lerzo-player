import SwiftUI

/// What the on-screen display is currently reporting. Values are read live
/// from the player when drawn, so a burst of key presses always shows the
/// final value rather than the one at the time of the press.
public enum OSDItem: Equatable {
    case speed
    case volume
    case seek(seconds: Double)
    case replayLine
    case nextLine
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
        case .replayLine: return "backward.end.alt.fill"
        case .nextLine: return "forward.end.alt.fill"
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
        case .nextLine:
            return String(localized: "Next line")
        }
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
