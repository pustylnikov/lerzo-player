# TODO

Что осталось до первого публичного релиза, и что можно сделать потом.

## Релиз

- [ ] **Иконка приложения** — положить `Resources/AppIcon.icns`; `scripts/release.sh` сам
      скопирует её в бандл и пропишет `CFBundleIconFile`. `build_app.sh` (dev-сборка)
      иконку пока не подхватывает.
- [ ] **Sparkle-автообновления** — подключить Sparkle 2, ключ EdDSA, `SUFeedURL`,
      генерировать appcast при релизе (`scripts/release.sh` уже делает DMG).
- [ ] **Окно About с лицензиями** — в бандл входят libmpv (GPLv2+/LGPLv2.1+) и ffmpeg;
      показать тексты GPL/LGPL и ссылку на исходники. Открытие исходников плеера на
      GitHub закрывает требования GPL для Homebrew-сборки mpv.
- [ ] **Прогнать `scripts/release.sh`** после того, как бинарник стал линковаться с ffmpeg
      напрямую (модуль `Cavformat`): убедиться, что проверка «Homebrew references remain»
      проходит, и ноутаризация проходит.
      `SIGN_IDENTITY="Developer ID Application: Yurii Pustylnikov (JL43U9V85R)" NOTARY_PROFILE=VPlayer scripts/release.sh`
- [ ] README: обновить таблицу горячих клавиш (сейчас перечислена только часть; полный
      список — `ShortcutsReference` в `ShortcutsOverlayView.swift`), описать внешние
      субтитры, задержки, масштабирование, Boost dialogue.
- [ ] Landing/privacy policy (ключ Gemini хранится в keychain, наружу уходит только текст
      реплик в Gemini API).

## Идеи на потом

- Индикатор чтения карты субтитров — нужен только если на каком-то файле
  `SubtitleTimeline` грузится заметно долго (MKV без Cues для субтитровой дорожки).
- Список реплик / навигация по диалогу — `SubtitleTimeline` уже хранит текст всех реплик.
- `updateEmbeddedWindowOrdering` вызывается на каждом проходе layout — работает, но
  избыточно.
