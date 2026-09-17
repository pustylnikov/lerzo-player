# Lerzo Player — заметки для агентов и разработчиков

Нативный macOS-видеоплеер для изучения языков: SwiftUI-интерфейс поверх libmpv,
разбор реплик через Gemini. Общение с автором — на русском; код, комментарии и
сообщения коммитов — на английском.

## Стек и сборка

- Имя продукта — «Lerzo Player» (бандл `Lerzo Player.app`, bundle id `com.lerzo.player`),
  исполняемый файл и SwiftPM-таргет — `LerzoPlayer`; папка репозитория историческая
  (`vplayer`). Общий бренд с мобильным приложением Lerzo — только имя и домен, ни кода,
  ни подписки общих нет.
- SwiftPM, один executable-таргет `LerzoPlayer` + системные модули `Cmpv` (libmpv) и
  `Cavformat` (libavformat/libavcodec/libavutil). Xcode-проекта нет. macOS 14+.
- Зависимости из Homebrew: `mpv` (0.41, `vo=gpu-next`, Vulkan через MoltenVK) и его
  дерево, включая ffmpeg. Заголовки и библиотеки берутся из `/opt/homebrew`.
- Dev-цикл: `./build_app.sh` → `build/Lerzo Player.app` (линкуется с Homebrew,
  подписывается Developer ID). Запуск для проверки:
  `pkill -x LerzoPlayer; sleep 1; open -a "$PWD/build/Lerzo Player.app" "$PWD/test_media/sample_dialogue.mkv"`
- Иконка: мастер `Resources/AppIcon.svg` (полноформатный квадрат 1024 в цветах Lerzo
  `#0A0A0B`/`#F2F2F4`), `swift scripts/make_icon.swift` вписывает его в сетку macOS
  (824 pt в холсте 1024) и собирает `Resources/AppIcon.icns`; оба файла в репозитории.
- Релиз: `scripts/release.sh` копирует libmpv и все dylib в бандл, переписывает
  install names, подписывает, ноутаризует, собирает DMG с папкой «Source code», затем
  подписывает DMG ключом Sparkle и пишет `dist/appcast.xml`; с `PUBLISH=1` создаёт релиз
  `v<версия>` на GitHub (`pustylnikov/lerzo-player`, через `gh`) с DMG. Appcast лежит на
  лендинге Lerzo (`https://lerzowords.com/player/appcast.xml`), а `enclosure url` в нём
  ведёт на GitHub Releases (см. шапку скрипта). Лендинг — отдельный репозиторий
  `/Volumes/MacDrive/Projects/anvilapp/projects/corewords/landing` (Next.js, статический
  экспорт, Firebase Hosting): страница `/player` берёт версию, размер и ссылку на DMG
  из `public/player/appcast.xml` через `yarn sync:player`; порядок публикации описан в
  разделе «Lerzo Player page» его README.
- Статистика: `scripts/downloads.sh` — загрузки каждого DMG с GitHub Releases (включая
  Sparkle-обновления) и трафик репозитория за 14 дней, через `gh`.
- Обновления: Sparkle 2 через SwiftPM (binary artifact в `.build/artifacts/sparkle`, там же
  `bin/generate_keys`, `sign_update`, `generate_appcast`). Фид
  `https://lerzowords.com/player/appcast.xml`, публичный ключ EdDSA — в шаблоне Info.plist
  в `build_app.sh`, приватный — в keychain автора. `UpdaterController.swift` — обёртка над
  `SPUStandardUpdaterController`. Оба скрипта кладут `Sparkle.framework` в
  `Contents/Frameworks`; в релизе его вложенные XPC/Autoupdate подписываются отдельно.
- Отладка mpv: `VPLAYER_MPV_LOG=/path/log open -a "build/Lerzo Player.app" file.mkv` —
  подробный лог mpv (команды, `Set property: …`). Stderr приложения:
  `open --stderr /path/log -a "build/Lerzo Player.app" file.mkv`.

## Архитектура (Sources/LerzoPlayer)

- `MPVPlayer.swift` — синглтон над libmpv: свойства через `mpv_observe_property`
  (id 1–23), команды, дорожки, задержки, геометрия картинки (zoom/pan/crop), фильтры
  звука, настройки картинки, карта субтитров. Публикует состояние для SwiftUI.
- `PlayerSurfaceView.swift` — NSView под окно mpv; mpv рисует в собственном NSWindow,
  который в оконном режиме прикреплён как child window, а в полноэкранном отделён и
  идёт на уровне `normal-1`. Иначе нельзя: полноэкранное окно — «дно» своего Space,
  всё на уровне 0 (в том числе child-окна, которым `addChildWindow` навязывает уровень
  родителя) оказывается поверх оверлея; поднять родителя на уровень выше тоже нельзя —
  такое окно не выходит из полного экрана и теряет сохранённый кадр. Но окно ниже
  уровня 0 не попадает в анимацию переключения Spaces и после возврата «вплывает» из
  чёрного кадра, поэтому по `NSWorkspace.activeSpaceDidChange` оно держится на
  `normal`, пока наш Space не активен, и опускается на `normal-1` по возвращении.
  SwiftUI-оверлей — прозрачное окно поверх; при показе видео фон
  `Color.black.opacity(0.01)`, иначе клики проваливаются сквозь alpha-0 пиксели.
  Поведение окна mpv: `[.fullScreenAuxiliary, .moveToActiveSpace]`, никогда
  `.canJoinAllSpaces` (видео появлялось на других рабочих столах).
- Форма окна (`MPVPlayer`: `updateVideoAspect`, `fitWindowToVideo`, `applyWindowAspectLock`):
  при первом кадре файла (и смене crop/дорожки) окно подгоняется под пропорции картинки
  с сохранением ширины. Настройка «Изменение размера окна»: по умолчанию окно держит
  пропорции через `NSWindow.aspectRatio` (снимается в полном экране и без видео —
  сбросом через `resizeIncrements`), в свободном режиме лишняя высота — полосы над и
  под кадром (`osd-dimensions/mt|mb` → `videoTopMargin`/`videoBottomMargin`), куда
  `SubtitlesLayer.bandInset` кладёт субтитры, если они помещаются; добавленные полосы
  переносятся на следующий файл. Минимальный размер окна — `MPVPlayer.windowMinSize`
  через `.frame(minWidth:minHeight:)` в `ContentView` (SwiftUI перезаписывает
  `contentMinSize` на каждом проходе, так что задавать его напрямую бесполезно); он
  согласован с пропорцией, иначе AppKit при замке выводит ширину из минимальной высоты.
  `updateChildWindowFrame` на главном потоке работает синхронно: во время живого ресайза
  отложенное обновление оставляло белую полосу вдоль растущих краёв.
- `LerzoPlayerApp.swift` — `@main`, меню приложения (`CommandMenu`), `AppDelegate`.
- `ContentView.swift` — корневой экран, приветствие, диалоги открытия, связка колбэков
  `KeyboardMonitor`. `ControlsOverlayView.swift` — панель управления и её меню.
- `KeyboardMonitor.swift` — глобальный локальный монитор NSEvent. Клавиши матчатся по
  физическим keyCode (работают в любой раскладке). Голые клавиши — в
  `if flags.isEmpty { switch keyCode }`, Shift-аккорды — в `if flags == [.shift]`, и
  они должны идти раньше необёрнутых обработчиков стрелок. Ctrl/Option — системе.
  Клавиши-переключатели (пробел, P, L, M, B, F…) перечислены в `oneShotBareKeys` /
  `oneShotShiftKeys`: их автоповтор гасится, новую клавишу-переключатель добавлять туда.
- `SubtitlesLayer.swift`, `SubtitleStyle.swift` — собственная отрисовка субтитров
  (mpv-шные скрыты прозрачным цветом), интерактивные слова, TAB-подглядывание перевода.
- `SubtitleTimeline.swift` + `MatroskaSubtitleScanner.swift` — все реплики текущей
  дорожки для точного сикинга W/E/R. mpv-шный `sub-seek` видит только уже показанные
  события, поэтому не годится. Для MKV читается индекс Cues и только блоки субтитров
  (0.1–3 с на 20 ГБ); иначе libavformat (медленно — читает весь файл). Дорожка mpv ↔
  поток libavformat через `ff-index`; для MKV дорожка ищется как k-я субтитровая в
  Tracks с проверкой CodecID.
- `FramePreviewer.swift` — превью кадра при наведении на шкалу времени: второй,
  безоконный экземпляр libmpv (`vo=null`, без звука и субтитров, софтверное
  декодирование — для одного кадра на сик hwdec только медленнее) с фильтром `scale`
  до размера превью; кадр забирается через `screenshot-raw`. Пока курсор движется —
  сик по keyframe (25–45 мс на 1080p), когда остановился — точный. Через 20 с без
  запросов экземпляр уничтожается. Карточка рисуется в `ControlsOverlayView`
  (`seekPreview`): кадр, время и реплика из `SubtitleTimeline` в этот момент.
- `OSDView.swift` — всплывающая подсказка после нажатия клавиши; `OSDItem` перечисляет
  все виды. `ShortcutsOverlayView.swift` — `ShortcutsReference` — единый источник списка
  клавиш для шпаргалки (H) и настроек: новая клавиша добавляется туда.
- `GeminiService.swift`, `GeminiError.swift`, `KeychainStore.swift`,
  `ExplanationPopoverView.swift` — разбор реплики через Gemini; ключ в keychain.
- `DictionaryLookup.swift` — словарь по клику на слово: `DCSCopyTextDefinition` отдаёт статью
  плоским текстом, `SystemDictionary.lines(from:)` эвристически режет её на части речи,
  значения (только по порядку 1, 2, 3…), подзначения «•» и примеры «▸». Какой словарь
  отвечает первым, DCS выбирает по языку интерфейса приложения (русский UI → Oxford Russian,
  английский → NOAD), поэтому в CLI-пробах передавать `-AppleLanguages "(ru)"`.
- `AboutView.swift` — окно About (отдельная `Window`-сцена `about`): версия, текст GPLv3 из
  `Resources/LICENSE`, список библиотек из `THIRD-PARTY-SOURCES.md` (есть только в релизной
  сборке), ссылки `AboutInfo`. Пока оно ключевое, `KeyboardMonitor` не перехватывает клавиши.
- `PlaybackHistory.swift` — позиции недосмотренных файлов (`playback-positions.json` рядом с
  `cards.json`, до 500 записей, ключ — путь + размер файла). `MPVPlayer` пишет позицию при
  смене файла, паузе, выходе и каждые 30 с воспроизведения; файл считается досмотренным
  при ≥ 95 % или < 30 с до конца, не начатым — при < 10 с (запись удаляется). Восстановление —
  через опцию `start=` в `loadfile` (без мелькания первого кадра), OSD «Продолжение с …».
- `SettingsView.swift` — лист настроек 640 pt; `LanguagePreferences.swift` — автовыбор
  дорожек по языкам; `TrackModels.swift` — модели дорожек.
- HDR (`MPVPlayer`: `hdrOutputEnabled`, `displaySupportsHDR`, `updateHDROutput`,
  `updateOverlayEDRFlag`; бейдж — в `ControlsOverlayView`): при включённой настройке и
  экране с EDR (`maximumPotentialExtendedDynamicRangeColorComponentValue > 1`) ставится
  `target-colorspace-hint=yes`; gpu-next/macvk через MoltenVK берёт swapchain
  `A2R10G10B10 + HDR10_ST2084`, переводит Metal-слой в BT.2100 PQ с
  `wantsExtendedDynamicRangeContent` и `CAEDRMetadata` HDR10 (пик 1000 нит — дефолт
  libplacebo: дисплей mpv на macOS не опрашивает; подгонку под реальный headroom экрана
  по этим метаданным делает сам macOS). В логе `VPLAYER_MPV_LOG` это строки `Picked
  surface configuration … HDR10_ST2084_EXT`, `Metal layer colorspace changed:
  ITUR_2100_PQ`, `Metal layer HDR active`. Проверено 2026-09-17 (M4, LG HDR 5K):
  вывод попиксельно совпадает с `mpv --vo=gpu-next --target-colorspace-hint=yes` и в
  пределах пары процентов — с QuickTime Player. IINA выглядит насыщеннее и контрастнее не
  потому, что «больше HDR»: он рендерит в CAOpenGLLayer без EDR-метаданных и без
  гамут-маппинга, и примари BT.2020 клиппятся в чистые 255/0/0. Обнулять `edrMetadata`
  на слое mpv нельзя — без метаданных macOS показывает PQ пересвеченным и блёклым.
  Эффект HDR на глаз слабый, когда монитор выставлен ярко (headroom LG при высокой
  яркости SDR ≈ 1.3 из потенциальных 6) и когда контент сведён темно (у сериалов ATVP
  пики ≈ 200 нит). Как сравнивать: `screencapture -x` и пиксели одной сцены в Lerzo,
  голом mpv и QuickTime. ScreenCaptureKit с `captureDynamicRange` для этого не годится:
  масштаб его значений разный у разных приложений и меняется во времени без изменений
  на экране; `NSScreen.maximumExtendedDynamicRangeColorComponentValue` у внешнего
  монитора — константа от яркости SDR, а не индикатор включившегося HDR.

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
  `@ObservedObject player` в `LerzoPlayerApp`.
- Открытие файлов из Finder/`open` приходит в SwiftUI `.onOpenURL`, а не только в
  `AppDelegate`; все пути ведут в `MPVPlayer.open(url:)` (видео или субтитры по расширению).
- `screenshot-raw` работает с videotoolbox hwdec, `cropdetect` — нет (используется для
  «Убрать чёрные полосы»).
- Не запрашивать и не выводить app-specific пароль Apple и ключ Gemini; не читать ключ
  из keychain в командах.

## Лицензия и распространение

- Homebrew-сборки mpv и ffmpeg — GPL (ffmpeg — GPLv3+ из-за `--enable-version3`), поэтому
  плеер распространяется под GPLv3, а исходники кладутся в DMG рядом с приложением
  (GPLv3 §6(a)) и линкуются из About. Мобильного приложения Lerzo это не касается.
- Mac App Store с GPL-сборкой невозможен; при необходимости — своя LGPL-сборка mpv
  (`-Dgpl=false`) и ffmpeg (без `--enable-gpl`): функциональность плеера не теряется,
  меняются только скрипты сборки.

## Тестовые файлы

`test_media/sample_dialogue.mkv` (2 дорожки субтитров, en/ru), `letterboxed.mkv`
(чёрные полосы, ожидаемый crop `1280x720+60+100`), `hdr_sample.mp4`, `en.srt`, `ru.srt`.
`test_media/sintel/` (в `.gitignore`, 1,2 ГБ) — официальный Sintel 1080p с
download.blender.org (CC BY 3.0, встроенные en/ru субтитры) для скриншотов лендинга;
hero снят на реплике 01:58 «You're a fool for traveling alone…» в окне 1440×900 pt.

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

Список оставшихся задач — в `TODO.md`, пошаговая процедура релиза и деплоя лендинга —
в `CLAUDE.local.md` (оба — локальные файлы автора, в git не входят).
