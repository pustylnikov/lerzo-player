# Lerzo Player — notes for agents and developers

A native macOS video player for language learners: a SwiftUI interface on top of
libmpv, with subtitle lines explained by Gemini. Code, comments and commit messages
are in English.

## Stack and build

- The product name is "Lerzo Player" (bundle `Lerzo Player.app`, bundle id
  `com.lerzo.player`); the executable and the SwiftPM target are `LerzoPlayer`. It shares
  only the name and the domain with the Lerzo mobile app — no code, no subscription.
- SwiftPM, one executable target `LerzoPlayer` plus the system modules `Cmpv` (libmpv)
  and `Cavformat` (libavformat/libavcodec/libavutil). No Xcode project. macOS 14+.
- Dependencies come from Homebrew: `mpv` (0.41, `vo=gpu-next`, Vulkan via MoltenVK) and
  its tree, including ffmpeg. Headers and libraries are taken from `/opt/homebrew`.
- Dev loop: `./build_app.sh` → `build/Lerzo Player.app` (linked against Homebrew). When
  a Developer ID certificate is available, the dev build is signed with the hardened
  runtime and the same entitlements as the release, otherwise errors such as LuaJIT's JIT
  pages only show up for users; without one it keeps an ad-hoc signature. To run it:
  `pkill -x LerzoPlayer; sleep 1; open -a "$PWD/build/Lerzo Player.app" "$PWD/test_media/sample_dialogue.mkv"`
- Icon: the master is `Resources/AppIcon.svg` (a full-bleed 1024 square in the Lerzo
  colours `#0A0A0B`/`#F2F2F4`); `swift scripts/make_icon.swift` fits it into the macOS
  grid (824 pt in a 1024 canvas) and builds `Resources/AppIcon.icns`. Both files are in
  the repository.
- Release: `scripts/release.sh` copies libmpv and every dylib into the bundle, rewrites
  install names, signs, notarizes, builds a DMG with a "Source code" folder, then signs
  the DMG with the Sparkle key and writes `dist/appcast.xml`; with `PUBLISH=1` it creates
  the `v<version>` release on GitHub (`pustylnikov/lerzo-player`, via `gh`) with the DMG.
  The appcast is served from the Lerzo website (`https://lerzowords.com/player/appcast.xml`),
  and its `enclosure url` points at GitHub Releases (see the script header).
- Statistics: `scripts/downloads.sh` — downloads of every DMG from GitHub Releases
  (including Sparkle updates) and repository traffic for the last 14 days, via `gh`.
- Updates: Sparkle 2 through SwiftPM (binary artifact in `.build/artifacts/sparkle`,
  together with `bin/generate_keys`, `sign_update`, `generate_appcast`). The feed is
  `https://lerzowords.com/player/appcast.xml`; the public EdDSA key is in the Info.plist
  template in `build_app.sh`, the private key is kept outside the repository.
  `UpdaterController.swift` wraps `SPUStandardUpdaterController`. Both scripts put
  `Sparkle.framework` into `Contents/Frameworks`; in the release its nested XPC services
  and Autoupdate are signed separately.
- Debugging mpv: `VPLAYER_MPV_LOG=/path/log open -a "build/Lerzo Player.app" file.mkv`
  writes a verbose mpv log (commands, `Set property: …`). The app's stderr:
  `open --stderr /path/log -a "build/Lerzo Player.app" file.mkv`.

## Architecture (Sources/LerzoPlayer)

- `MPVPlayer.swift` — a singleton over libmpv: properties via `mpv_observe_property`
  (ids 1–23), commands, tracks, delays, picture geometry (zoom/pan/crop), audio filters,
  picture settings, the subtitle map. Publishes state for SwiftUI.
- `PlayerSurfaceView.swift` — the NSView under the mpv window. mpv draws into its own
  NSWindow, which in windowed mode is attached as a child window and in full screen is
  detached and runs at level `normal-1`. There is no other way: a full-screen window is
  the "floor" of its Space, and everything at level 0 (including child windows, which
  `addChildWindow` forces to the parent's level) ends up above the overlay; raising the
  parent a level higher does not work either — such a window cannot leave full screen and
  loses its saved frame. But a window below level 0 is left out of the Space-switch
  animation and "floats in" from a black frame on return, so on
  `NSWorkspace.activeSpaceDidChange` it stays at `normal` while our Space is inactive and
  drops to `normal-1` when we come back. The SwiftUI overlay is a transparent window on
  top; while video is shown its background is `Color.black.opacity(0.01)`, otherwise
  clicks fall through alpha-0 pixels. mpv window behaviour:
  `[.fullScreenAuxiliary, .moveToActiveSpace]`, never `.canJoinAllSpaces` (the video
  showed up on other desktops).
- Window shape (`MPVPlayer`: `updateVideoAspect`, `fitWindowToVideo`,
  `applyWindowAspectLock`): on a file's first frame (and on crop/track changes) the
  window is fitted to the picture's proportions, keeping its width. The "Resizing the
  window" setting: by default the window keeps the proportions through
  `NSWindow.aspectRatio` (dropped in full screen and without video — reset through
  `resizeIncrements`); in free mode extra height becomes bands above and below the
  picture (`osd-dimensions/mt|mb` → `videoTopMargin`/`videoBottomMargin`), where
  `SubtitlesLayer.bandInset` places subtitles when they fit; added bands carry over to
  the next file. The minimum window size is `MPVPlayer.windowMinSize`, applied through
  `.frame(minWidth:minHeight:)` in `ContentView` (SwiftUI overwrites `contentMinSize` on
  every pass, so setting it directly is useless); it is kept consistent with the aspect
  ratio, otherwise AppKit derives the width from the minimum height while locked.
  `updateChildWindowFrame` runs synchronously on the main thread: during live resize a
  deferred update left a white strip along the growing edges.
- `LerzoPlayerApp.swift` — `@main`, the app menu (`CommandMenu`), `AppDelegate`.
- `ContentView.swift` — the root screen, welcome screen, open dialogs, wiring of
  `KeyboardMonitor` callbacks. `ControlsOverlayView.swift` — the control bar and its menus.
- `KeyboardMonitor.swift` — a global local NSEvent monitor. Keys are matched by physical
  keyCode (they work in any keyboard layout). Bare keys go in
  `if flags.isEmpty { switch keyCode }`, Shift chords in `if flags == [.shift]`, and
  those must come before the unwrapped arrow handlers. Ctrl/Option belong to the system.
  Toggle keys (Space, P, L, M, B, F…) are listed in `oneShotBareKeys` /
  `oneShotShiftKeys`, which suppress their auto-repeat; add any new toggle key there.
- `SubtitlesLayer.swift`, `SubtitleStyle.swift` — our own subtitle rendering (mpv's are
  hidden with a transparent colour), interactive words, TAB to peek at the translation.
- `SubtitleTimeline.swift` + `MatroskaSubtitleScanner.swift` — every line of the current
  track, for precise W/E/R seeking. mpv's `sub-seek` only sees events already shown, so it
  does not work for this. For MKV the Cues index is read and only subtitle blocks are
  loaded (0.1–3 s for 20 GB); otherwise libavformat is used (slow — it reads the whole
  file). mpv track ↔ libavformat stream through `ff-index`; for MKV the track is found as
  the k-th subtitle track in Tracks, checking the CodecID.
- `FramePreviewer.swift` — the frame preview when hovering over the timeline: a second,
  windowless libmpv instance (`vo=null`, no audio or subtitles, software decoding — for a
  single frame per seek hwdec is only slower) with a `scale` filter down to the preview
  size; the frame is taken with `screenshot-raw`. HDR sources (PQ/HLG) are taken as 16-bit
  `rgba64` and converted to sRGB in Swift (`HDRThumbnail`: EOTF → BT.2390 at 203-nit
  reference white → BT.2020→709 → sRGB; in the "Accurate" HDR mode the picture is dimmed a
  little to match absolute PQ). swscale cannot do it: mpv rebuilds the filter graph on
  every seek, and any colour conversion (`out_transfer`, `intent`, `tonemap`) adds
  300–500 ms to build the LUT; a plain `scale` takes 25–60 ms. This instance has
  `sws-allow-zimg=no`: by default mpv takes screenshots through zimg, which converts
  PQ/BT.2020 to sRGB itself (clipping, no tone mapping), and `HDRThumbnail` then applied
  the PQ curve to data that was already sRGB — the preview came out garishly saturated.
  While the cursor moves, seeks go to keyframes (25–45 ms on 1080p); once it stops, the
  seek is exact. The request and a click on the timeline are rounded down to the whole
  second shown on the card, so the jump lands on the same frame. After 20 s without
  requests the instance is destroyed. The card is drawn in `ControlsOverlayView`
  (`seekPreview`): the frame with the line from `SubtitleTimeline` and the time.
- `OSDView.swift` — the hint shown after a key press; `OSDItem` lists all kinds.
  `ShortcutsOverlayView.swift` — `ShortcutsReference` is the single source of the key
  list for the cheat sheet (H) and Settings: add new keys there.
- `GeminiService.swift`, `GeminiError.swift`, `KeychainStore.swift`,
  `ExplanationPopoverView.swift` — line breakdowns through Gemini; the key lives in the
  keychain.
- `DictionaryLookup.swift` — dictionary on word click: `DCSCopyTextDefinition` returns the
  entry as plain text, and `SystemDictionary.lines(from:)` heuristically splits it into
  parts of speech, senses (numbered 1, 2, 3… only), sub-senses "•" and examples "▸".
  Which dictionary answers first depends on the app's UI language (Russian UI → Oxford
  Russian, English → NOAD), so pass `-AppleLanguages "(ru)"` in CLI probes.
- `AboutView.swift` — the About window (a separate `Window` scene `about`): version, the
  GPLv3 text from `Resources/LICENSE`, the library list from `THIRD-PARTY-SOURCES.md`
  (present only in the release build), `AboutInfo` links. While it is key,
  `KeyboardMonitor` does not intercept keys.
- `FileRecordStore.swift` — shared storage for per-file records (a JSON array in
  Application Support next to `cards.json`, keyed by path, up to 500 records; a record for
  a different file with the same name is dropped by size; deferred writes, flushed on quit).
- `PlaybackHistory.swift` — positions of unfinished files (`playback-positions.json`; do
  not change the format — earlier versions read it). `MPVPlayer` writes the position on
  file change, pause, quit and every 30 s of playback; a file counts as finished at ≥ 95 %
  or < 30 s before the end, and as not started at < 10 s (the record is removed). Resuming
  goes through the `start=` option of `loadfile` (no flash of the first frame), with the
  OSD "Resuming from …".
- `FileSettings.swift` — per-file settings in a separate `file-settings.json` (kept after
  a file is finished): non-zero delays (`delays`, keyed by mpv property; set before
  `loadfile`, since mpv delays are global), manually loaded subtitles
  (`externalSubtitles`, `sub-add … auto` after FILE_LOADED) and tracks chosen in the menu
  (`tracks`: `aid`/`sid`/`secondary-sid` → `RememberedTrack`: off, embedded by id +
  language + title, or external by path). Only the user's choice is written, and only if
  mpv accepted it (`pickTrack` re-reads the tracks; mpv does not give one track both
  roles) — never the automatic selection: the other roles are picked from the languages
  on open (`selectInitialTracks`). Settings are applied only if FILE_LOADED arrived for the
  file that is open now (the `path` property) — otherwise, when switching files quickly,
  they would land on the previous one.
- `SettingsView.swift` — the 640 pt settings sheet; `LanguagePreferences.swift` —
  automatic track selection by language; `TrackModels.swift` — track models. The HDR
  toggle and mode picker live in the "Picture" section, next to the global picture
  adjustments.
- HDR (`MPVPlayer`: `hdrOutputEnabled`, `displaySupportsHDR`, `updateHDROutput`,
  `updateOverlayEDRFlag`; the badge is in `ControlsOverlayView`): with the setting on and
  an EDR screen (`maximumPotentialExtendedDynamicRangeColorComponentValue > 1`),
  `target-colorspace-hint=yes` is set. The setting has two modes: "Accurate" —
  `target-colorspace-hint-mode=source-dynamic`, no brightness expansion; "Vivid" (the
  default) — `target` mode with `inverse-tone-mapping=yes` and
  `tone-mapping-max-boost=2.0`, i.e. adaptation to the display and at most one extra stop
  of brightness for low-peak scenes. Because mpv/macvk otherwise treats an unknown display
  as 10,000 nits, `target-peak` is computed as the current
  `maximumExtendedDynamicRangeColorComponentValue × 203` nits (capped at 1000). With HDR
  off the expansion is disabled so the ordinary HDR→SDR tone mapping is unchanged.
  gpu-next/macvk through MoltenVK takes an `A2R10G10B10 + HDR10_ST2084` swapchain and
  switches the Metal layer to BT.2100 PQ with `wantsExtendedDynamicRangeContent` and
  HDR10 `CAEDRMetadata`. `source-dynamic` takes the scene brightness from Dolby Vision,
  then HDR10+, falling back to static metadata; macOS adapts the picture to the screen
  from that metadata. This is an experimental mpv mode: scene brightness is passed through
  HDR10, not full Dolby Vision/HDR10+. In a `VPLAYER_MPV_LOG` log it shows as `Picked
  surface configuration … HDR10_ST2084_EXT`, `Metal layer colorspace changed:
  ITUR_2100_PQ`, `Metal layer HDR active`, `Metal layer HDR metadata changed`.
  The VideoToolbox decoder keeps dynamic metadata, but the `target` mode passes only the
  static peak (≈ 1000 nits), while in `source-dynamic` Metal receives the per-scene peak
  and the picture gets close to QuickTime. HDR10+ files without Dolby Vision still differ,
  so an exact match for every file is not guaranteed. Colour bars alone do not prove that
  HDR matches QuickTime.
  `test_media/hdr_sample.mp4` is no brightness reference: it declares MaxCLL 1000 nits,
  but its first frame has PQ values up to ≈ 9400 nits. Check on real scenes and correctly
  encoded grey steps, away from the control bar gradient. Pixel values in a capture are
  not the display's physical brightness; white saturation in an IINA capture does not by
  itself prove clipping on screen. Do not clear `edrMetadata` on mpv's layer — without
  metadata macOS shows PQ blown out and washed out. The HDR effect looks weak when the
  monitor's SDR brightness is set high (little EDR headroom left) and when the content is
  mastered dark (some streaming series peak around 200 nits). How to compare:
  `screencapture -x` and the pixels of one scene in Lerzo, bare mpv and QuickTime.
  ScreenCaptureKit with `captureDynamicRange` does not work for this: the scale of its
  values differs between apps and drifts over time with nothing changing on screen;
  `NSScreen.maximumExtendedDynamicRangeColorComponentValue` of an external monitor is a
  constant derived from SDR brightness, not an indicator that HDR has kicked in.

## Localization

`Resources/{en,ru}.lproj/Localizable.strings`, the English text is the key. For `String`
contexts use `String(localized:)`. In `.strings` keys a percent sign is escaped as `%%`,
in Swift interpolations it is a single `%`. Check: `plutil -lint Resources/*/Localizable.strings`.

## Known pitfalls

- Nested `Menu`s inside control bar menus are rebuilt on every `time-pos` update and do
  not open during playback — keep control bar menu items flat. Submenus work in
  `CommandMenu` (the app menu).
- A `Toggle` in a `CommandMenu` gives a checkmark; menu item titles depend on
  `@ObservedObject player` in `LerzoPlayerApp`.
- Files opened from Finder/`open` arrive in SwiftUI `.onOpenURL`, not only in
  `AppDelegate`; every path leads to `MPVPlayer.open(url:)` (video or subtitles by
  extension).
- `screenshot-raw` works with videotoolbox hwdec, `cropdetect` does not (it is used for
  "Remove black bars").
- Never ask for or print the Gemini key, and do not read it from the keychain in commands.

## License and distribution

- Homebrew builds of mpv and ffmpeg are GPL (ffmpeg is GPLv3+ because of
  `--enable-version3`), so the player is distributed under GPLv3, and the source is shipped
  in the DMG next to the app (GPLv3 §6(a)) and linked from About. This does not concern
  the Lerzo mobile app.
- The Mac App Store is impossible with a GPL build; if ever needed — a custom LGPL build
  of mpv (`-Dgpl=false`) and ffmpeg (without `--enable-gpl`): the player loses no
  functionality, only the build scripts change.

## Test files

`test_media/sample_dialogue.mkv` (2 subtitle tracks, en/ru), `letterboxed.mkv` (black
bars, expected crop `1280x720+60+100`), `hdr_sample.mp4`, `en.srt`, `ru.srt`.
`test_media/sintel/` (in `.gitignore`, 1.2 GB) — the official Sintel 1080p from
download.blender.org (CC BY 3.0, embedded en/ru subtitles).

## Documentation

- libmpv API: https://mpv.io/manual/master/#embedding-into-other-programs-libmpv and
  https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
- mpv properties and commands: https://mpv.io/manual/master/#properties ,
  https://mpv.io/manual/master/#list-of-input-commands (`sub-seek`, `video-zoom`,
  `video-pan-x/y`, `panscan`, `video-crop`, `sub-delay`, `secondary-sub-delay`,
  `audio-delay`, `af`, `screenshot-raw`)
- ffmpeg filters for Boost dialogue: https://ffmpeg.org/ffmpeg-filters.html#pan ,
  https://ffmpeg.org/ffmpeg-filters.html#dynaudnorm
- libavformat: https://ffmpeg.org/doxygen/trunk/group__lavf__decoding.html
- Matroska/EBML: https://www.matroska.org/technical/elements.html ,
  https://www.matroska.org/technical/cues.html
- Gemini API: https://ai.google.dev/api
- Sparkle: https://sparkle-project.org/documentation/
- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
