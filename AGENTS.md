# VPlayer — заметки для агентов и разработчиков

Нативный macOS-видеоплеер для изучения языков: SwiftUI-интерфейс поверх libmpv,
разбор реплик через Gemini. Общение с автором — на русском; код, комментарии и
сообщения коммитов — на английском.

## Стек и сборка

- SwiftPM, один executable-таргет `VPlayer` + системные модули `Cmpv` (libmpv) и
  `Cavformat` (libavformat/libavcodec/libavutil). Xcode-проекта нет. macOS 14+.
- Зависимости из Homebrew: `mpv` (0.41, `vo=gpu-next`, Vulkan через MoltenVK) и его
  дерево, включая ffmpeg. Заголовки и библиотеки берутся из `/opt/homebrew`.
- Dev-цикл: `./build_app.sh` → `build/VPlayer.app` (линкуется с Homebrew, подписывается
  Developer ID). Запуск для проверки:
  `pkill -x VPlayer; sleep 1; open -a "$PWD/build/VPlayer.app" "$PWD/test_media/sample_dialogue.mkv"`
- Релиз: `scripts/release.sh` копирует libmpv и все dylib в бандл, переписывает
  install names, подписывает, ноутаризует, собирает DMG (см. шапку скрипта).
- Отладка mpv: `VPLAYER_MPV_LOG=/path/log open -a build/VPlayer.app file.mkv` —
  подробный лог mpv (команды, `Set property: …`).

## Архитектура (Sources/VPlayer)

- `MPVPlayer.swift` — синглтон над libmpv: свойства через `mpv_observe_property`
  (id 1–23), команды, дорожки, задержки, геометрия картинки (zoom/pan/crop), фильтры
  звука, настройки картинки, карта субтитров. Публикует состояние для SwiftUI.
- `PlayerSurfaceView.swift` — NSView под окно mpv; mpv рисует в собственном NSWindow,
  который в оконном режиме прикреплён как child window, а в полноэкранном отделён и
  идёт на уровне `normal-1`. SwiftUI-оверлей — прозрачное окно поверх; при показе видео
  фон `Color.black.opacity(0.01)`, иначе клики проваливаются сквозь alpha-0 пиксели.
  Поведение окна mpv: `[.fullScreenAuxiliary, .moveToActiveSpace]`, никогда
  `.canJoinAllSpaces` (видео появлялось на других рабочих столах).
- `ContentView.swift` — корневой экран, приветствие, диалоги открытия, связка колбэков
  `KeyboardMonitor`. `ControlsOverlayView.swift` — панель управления и её меню.
- `KeyboardMonitor.swift` — глобальный локальный монитор NSEvent. Клавиши матчатся по
  физическим keyCode (работают в любой раскладке). Голые клавиши — в
  `if flags.isEmpty { switch keyCode }`, Shift-аккорды — в `if flags == [.shift]`, и
  они должны идти раньше необёрнутых обработчиков стрелок. Ctrl/Option — системе.
- `SubtitlesLayer.swift`, `SubtitleStyle.swift` — собственная отрисовка субтитров
  (mpv-шные скрыты прозрачным цветом), интерактивные слова, TAB-подглядывание перевода.
- `SubtitleTimeline.swift` + `MatroskaSubtitleScanner.swift` — все реплики текущей
  дорожки для точного сикинга W/E/R. mpv-шный `sub-seek` видит только уже показанные
  события, поэтому не годится. Для MKV читается индекс Cues и только блоки субтитров
  (0.1–3 с на 20 ГБ); иначе libavformat (медленно — читает весь файл). Дорожка mpv ↔
  поток libavformat через `ff-index`; для MKV дорожка ищется как k-я субтитровая в
  Tracks с проверкой CodecID.
- `OSDView.swift` — всплывающая подсказка после нажатия клавиши; `OSDItem` перечисляет
  все виды. `ShortcutsOverlayView.swift` — `ShortcutsReference` — единый источник списка
  клавиш для шпаргалки (H) и настроек: новая клавиша добавляется туда.
- `GeminiService.swift`, `GeminiError.swift`, `KeychainStore.swift`,
  `ExplanationPopoverView.swift` — разбор реплики через Gemini; ключ в keychain.
- `SettingsView.swift` — лист настроек 640 pt; `LanguagePreferences.swift` — автовыбор
  дорожек по языкам; `TrackModels.swift` — модели дорожек.

## Локализация

`Resources/{en,ru}.lproj/Localizable.strings`, английский текст — ключ. Для `String`
контекстов — `String(localized:)`. В ключах `.strings` процент экранируется `%%`, в
Swift-интерполяциях — одиночный `%`. Проверка: `plutil -lint Resources/*/Localizable.strings`.
Меню в рантайме у автора на русском (важно для osascript-тестов).

## Известные грабли

- Вложенные `Menu` внутри меню панели управления пересоздаются на каждом обновлении
  `time-pos` и не открываются во время воспроизведения — пункты меню панели держать
  плоскими. В `CommandMenu` (меню приложения) подменю работают.
- `Toggle` в `CommandMenu` даёт галочку; заголовки пунктов зависят от
  `@ObservedObject player` в `VPlayerApp`.
- Открытие файлов из Finder/`open` приходит в SwiftUI `.onOpenURL`, а не только в
  `AppDelegate`; все пути ведут в `MPVPlayer.open(url:)` (видео или субтитры по расширению).
- `screenshot-raw` работает с videotoolbox hwdec, `cropdetect` — нет (используется для
  «Убрать чёрные полосы»).
- Не запрашивать и не выводить app-specific пароль Apple и ключ Gemini; не читать ключ
  из keychain в командах.

## Тестовые файлы

`test_media/sample_dialogue.mkv` (2 дорожки субтитров, en/ru), `letterboxed.mkv`
(чёрные полосы, ожидаемый crop `1280x720+60+100`), `hdr_sample.mp4`, `en.srt`, `ru.srt`.

## Документация

- libmpv API: https://mpv.io/manual/master/#embedding-into-other-programs-libmpv и
  https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
- Свойства и команды mpv: https://mpv.io/manual/master/#properties ,
  https://mpv.io/manual/master/#list-of-input-commands (`sub-seek`, `video-zoom`,
  `video-pan-x/y`, `panscan`, `video-crop`, `sub-delay`, `secondary-sub-delay`,
  `audio-delay`, `af`, `screenshot-raw`)
- ffmpeg-фильтры для Boost dialogue: https://ffmpeg.org/ffmpeg-filters.html#pan ,
  https://ffmpeg.org/ffmpeg-filters.html#dynaudnorm
- libavformat: https://ffmpeg.org/doxygen/trunk/group__lavf__decoding.html
- Matroska/EBML: https://www.matroska.org/technical/elements.html ,
  https://www.matroska.org/technical/cues.html
- Gemini API: https://ai.google.dev/api
- Sparkle: https://sparkle-project.org/documentation/
- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

Список оставшихся задач — в `TODO.md`.
