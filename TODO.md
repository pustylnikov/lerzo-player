# TODO

Что осталось до первого публичного релиза, и что можно сделать потом.

## Релиз

- [x] Переименование в Lerzo Player, bundle id `com.lerzo.player`.
- [x] Иконка приложения — `Resources/AppIcon.svg` (мастер, play в кольце в цветах Lerzo),
      `swift scripts/make_icon.swift` собирает `AppIcon.icns` на сетке macOS.
- [ ] **Исходники в DMG** — `scripts/release.sh` должен класть `Source code.zip`
      (`git archive` текущего коммита) рядом с приложением: так выполняется GPLv3 §6(a) и
      на лендинге репозиторий упоминать не обязательно.
- [ ] **LICENSE** — файл GPLv3 в корне репозитория; публичный репозиторий (например,
      `lerzo-player`), ссылка на него — в About.
- [ ] **Страница плеера на лендинге Lerzo** — отдельный бесплатный open-source плеер для
      macOS, без связи с подпиской приложения; там же DMG и `appcast.xml` для Sparkle.
- [ ] **Sparkle-автообновления** — подключить Sparkle 2, ключ EdDSA, `SUFeedURL`,
      генерировать appcast при релизе (`scripts/release.sh` уже делает DMG).
- [ ] **Окно About с лицензиями** — плеер под GPLv3; в бандл входят libmpv (GPL) и ffmpeg
      (GPLv3+), libass, libplacebo, MoltenVK и др. — показать тексты лицензий и ссылку на
      репозиторий.
- [ ] **Прогнать `scripts/release.sh`** после того, как бинарник стал линковаться с ffmpeg
      напрямую (модуль `Cavformat`): убедиться, что проверка «Homebrew references remain»
      проходит, и ноутаризация проходит.
      `SIGN_IDENTITY="Developer ID Application: Yurii Pustylnikov (JL43U9V85R)" NOTARY_PROFILE=VPlayer scripts/release.sh`
      (`VPlayer` — имя существующего keychain-профиля notarytool, его менять не нужно).
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
