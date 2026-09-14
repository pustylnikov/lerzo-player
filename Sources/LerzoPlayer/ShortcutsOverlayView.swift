import SwiftUI

/// One row of the cheat sheet. `keys` is shown as a key cap; it is a
/// localized key because a few names ("Space") have translations.
struct ShortcutEntry: Identifiable {
    let keys: LocalizedStringKey
    let action: LocalizedStringKey
    var id: String { "\(keys)" }
}

struct ShortcutGroup: Identifiable {
    let title: LocalizedStringKey
    let icon: String
    let entries: [ShortcutEntry]
    var id: String { "\(title)" }
}

/// Single source of truth for the shortcut list: the H overlay and the
/// Settings section both render from here, so a new key cannot be
/// documented in one place and forgotten in the other.
enum ShortcutsReference {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Language learning", icon: "graduationcap.fill", entries: [
            ShortcutEntry(keys: "TAB", action: "Hold: instantly peek at the translation (second subtitle track)"),
            ShortcutEntry(keys: "⇧ + TAB", action: "Keep the translation on screen on / off"),
            ShortcutEntry(keys: "R", action: "Replay the current line from the start"),
            ShortcutEntry(keys: "W  /  E", action: "Previous / next line of dialogue"),
            ShortcutEntry(keys: "P", action: "Pause at the end of every line on / off (R, W, E play on)"),
            ShortcutEntry(keys: "L", action: "Repeat the current line on / off"),
            ShortcutEntry(keys: "⇧ + L", action: "A–B loop: mark the start, mark the end, clear"),
            ShortcutEntry(keys: "⌘ + G", action: "AI breakdown of the current line with Gemini"),
        ]),
        ShortcutGroup(title: "Playback", icon: "play.fill", entries: [
            ShortcutEntry(keys: "Space", action: "Pause / Play"),
            ShortcutEntry(keys: "←  /  →", action: "Seek 5 seconds back / forward"),
            ShortcutEntry(keys: "↑  /  ↓", action: "Volume +5% / −5%"),
            ShortcutEntry(keys: "M", action: "Mute / unmute"),
            ShortcutEntry(keys: "B", action: "Boost dialogue on / off"),
            ShortcutEntry(keys: "[  /  ]", action: "Speed: slower / faster by 0.1×"),
            ShortcutEntry(keys: "⌫", action: "Reset speed to 1×"),
        ]),
        ShortcutGroup(title: "Sync", icon: "timer", entries: [
            ShortcutEntry(keys: "Z  /  X", action: "Subtitle delay: earlier / later by 0.1 s"),
            ShortcutEntry(keys: "⇧ + Z  /  ⇧ + X", action: "Audio delay: earlier / later by 0.1 s"),
        ]),
        ShortcutGroup(title: "Picture", icon: "aspectratio", entries: [
            ShortcutEntry(keys: "=  /  −", action: "Zoom in / out"),
            ShortcutEntry(keys: "⇧ + arrows", action: "Move the picture"),
            ShortcutEntry(keys: "0", action: "Reset zoom and position"),
        ]),
        ShortcutGroup(title: "General", icon: "macwindow", entries: [
            ShortcutEntry(keys: "F", action: "Full screen"),
            ShortcutEntry(keys: "⌘ + O", action: "Open a video or an external subtitle file"),
            ShortcutEntry(keys: "⌘ + ⇧ + O", action: "Load an external subtitle file"),
            ShortcutEntry(keys: "⌘ + ,", action: "Settings"),
            ShortcutEntry(keys: "H", action: "Show / hide this cheat sheet"),
            ShortcutEntry(keys: "Esc", action: "Close a panel, or leave full screen"),
        ]),
    ]
}

struct KeyCapView: View {
    let keys: LocalizedStringKey

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.15))
            .cornerRadius(5)
            .frame(minWidth: 65, alignment: .center)
    }
}

struct ShortcutRowView: View {
    let entry: ShortcutEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyCapView(keys: entry.keys)
            Text(entry.action)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Cheat sheet drawn over the video on H. It does not pause or take
/// focus: every shortcut keeps working while the sheet is up, so the user
/// can read a key and try it at once.
public struct ShortcutsOverlayView: View {
    @Binding var isOpen: Bool

    public init(isOpen: Binding<Bool>) {
        self._isOpen = isOpen
    }

    public var body: some View {
        ZStack {
            // Click anywhere outside the card closes it.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isOpen = false }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "keyboard")
                        .foregroundColor(.yellow)
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    Text("H or Esc to close")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Language learning + Sync + Picture on the left, Playback + General on the right.
                HStack(alignment: .top, spacing: 28) {
                    column([ShortcutsReference.groups[0], ShortcutsReference.groups[2], ShortcutsReference.groups[3]])
                    column([ShortcutsReference.groups[1], ShortcutsReference.groups[4]])
                }
            }
            .padding(20)
            .frame(width: 760)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
            .foregroundColor(.white)
        }
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Label(group.title, systemImage: group.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    ForEach(group.entries) { entry in
                        ShortcutRowView(entry: entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
