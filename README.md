# Lerzo Player 🎬

**Lerzo Player** is a native macOS video player for learning languages by watching films: **SwiftUI + libmpv + Google Gemini**. Subtitles are interactive, dialogue can be replayed line by line, a hidden translation is one key away, and any line can be explained by an AI.

---

## ✨ Features

- 🚀 **Hardware-accelerated playback:** MKV, MP4, WebM, AVI and everything else mpv plays, decoded by VideoToolbox and rendered with `gpu-next` (Metal via MoltenVK), HDR output included.
- 🪟 **One native window:** the video and the translucent SwiftUI interface share a single window.
- 💬 **Interactive subtitles:** hovering highlights words; clicking a word or the **“+ AI”** button sends the line for a breakdown focused on that expression.
- ⚡️ **Quick peek (`TAB`):** hold **`TAB`** to see the translation from the second subtitle track instantly; release it and the film goes on in the original language.
- 📑 **Dual subtitles (`⇧TAB`):** keep the translation on screen together with the original; each line can sit at the top or the bottom of the picture.
- ⏸ **Pause after each line (`P`) and loops (`L`, `⇧L`):** stop just before every line leaves the screen, repeat the current line until you have it, or mark an A–B loop by hand.
- 🧠 **AI breakdown with Gemini (`⌘ G`):** a detailed explanation of the line — idioms (*“under the weather”*, *“break a leg”*), slang, grammar and the subtext of the scene. Uses your own Google AI Studio key, stored in the keychain.
- 🔄 **Line-by-line navigation:** **`R`** replays the current line, **`W`** / **`E`** jump to the previous / next one. The player builds its own index of the track’s lines, so seeking is exact and works any number of lines in a row; for MKV the index is read from the Cues in a fraction of a second even on files of tens of gigabytes.
- 📄 **External subtitles:** `.srt`, `.ass`, `.vtt` files via ⌘⇧O, the open dialog or drag and drop; tracks are picked automatically by your preferred languages.
- 🎚 **Sync and sound:** subtitle, translation and audio delay in 0.1 s steps; *Boost dialogue* lifts speech and evens out loudness; playback speed.
- 🖼 **Picture:** zoom and pan, black-bar removal, brightness / contrast / gamma.
- ⚙️ **Settings (`⌘ ,`):** subtitle font and size with live preview, track languages, Gemini model.
- 🔄 **Automatic updates** via Sparkle.

---

## ⬇️ Download

Lerzo Player runs on macOS 14 or later (Apple silicon). Grab the DMG from the [releases page](../../releases) — the app is signed and notarized and updates itself.

No account, no analytics: the only things the player ever sends over the network are the subtitle line you ask Gemini to explain (with your own key) and a daily update check. Details in the [privacy policy](https://lerzowords.com/player/privacy).

---

## ⌨️ Keyboard shortcuts

Press **`H`** in the player for the built-in cheat sheet; in the source the list lives in `ShortcutsReference` (`ShortcutsOverlayView.swift`). Keys are matched by physical position, so they work in any keyboard layout.

### Language learning

| Key | Action |
| :--- | :--- |
| **`TAB` (hold)** | Peek at the translation (second subtitle track) |
| **`⇧TAB`** | Keep the translation on screen (dual subtitles) on / off |
| **`R`** | Replay the current line from the start |
| **`W` / `E`** | Previous / next line of dialogue |
| **`P`** | Pause at the end of every line on / off |
| **`L`** | Repeat the current line on / off |
| **`⇧L`** | A–B loop: mark the start, mark the end, clear |
| **`⌘ + G`** | AI breakdown of the current line with Gemini |

### Playback

| Key | Action |
| :--- | :--- |
| **`Space`** | Pause / play |
| **`←` / `→`** | Seek 5 seconds back / forward |
| **`↑` / `↓`** | Volume +5 % / −5 % |
| **`M`** | Mute / unmute |
| **`B`** | Boost dialogue on / off |
| **`[` / `]`** | Speed: slower / faster by 0.1× |
| **`⌫`** | Reset speed to 1× |

### Sync

| Key | Action |
| :--- | :--- |
| **`Z` / `X`** | Subtitle delay: earlier / later by 0.1 s |
| **`⇧ + Z` / `⇧ + X`** | Audio delay: earlier / later by 0.1 s |

### Picture

| Key | Action |
| :--- | :--- |
| **`=` / `−`** | Zoom in / out |
| **`⇧ + arrows`** | Move the picture |
| **`0`** | Reset zoom and position |

### General

| Key | Action |
| :--- | :--- |
| **`F`** | Full screen |
| **`⌘ + O`** | Open a video or an external subtitle file |
| **`⌘ + ⇧ + O`** | Load an external subtitle file |
| **`⌘ + ,`** | Settings |
| **`H`** | Show / hide the cheat sheet |
| **`Esc`** | Close a panel, or leave full screen |

---

## 🛠 Building from source

### 1. Dependencies

Xcode command line tools and mpv from Homebrew (it brings ffmpeg, libass, libplacebo and MoltenVK with it):

```bash
brew install mpv
```

Sparkle is fetched by SwiftPM on the first build.

### 2. Build and run

```bash
./build_app.sh
open "build/Lerzo Player.app"
```

`build_app.sh` produces a development bundle that links the Homebrew libraries in place. `scripts/release.sh` builds the self-contained, signed and notarized release DMG (see the header of the script).

---

## 🧪 Test media

The repository includes a short clip with colour bars and English / Russian subtitle tracks:

```bash
open -a "build/Lerzo Player.app" test_media/sample_dialogue.mkv
```

## 📄 License

Lerzo Player is free software under the [GNU GPL v3](LICENSE). The build bundles libmpv and ffmpeg (GPL) and their dependencies; every DMG carries a “Source code” folder with the source archive of that exact version and `THIRD-PARTY-SOURCES.md`, which lists every bundled library with its version, license and where to get its source.
