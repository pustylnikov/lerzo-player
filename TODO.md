# TODO

Что осталось до первого публичного релиза, и что можно сделать потом.

## Релиз

- [x] Переименование в Lerzo Player, bundle id `com.lerzo.player`.
- [x] Иконка приложения — `Resources/AppIcon.svg` (мастер, play в кольце в цветах Lerzo),
      `swift scripts/make_icon.swift` собирает `AppIcon.icns` на сетке macOS.
- [x] Исходники в DMG — `scripts/release.sh` кладёт папку «Source code» (`git archive`
      релизного коммита, `THIRD-PARTY-SOURCES.md` со всеми встроенными библиотеками и их
      исходниками, `LICENSE`); требует чистого рабочего дерева.
- [x] `LICENSE` (GPLv3) в корне репозитория; копия — в `Contents/Resources` бандла.
- [ ] **Публичный репозиторий** (например, `lerzo-player`); адрес — в
      `AboutInfo.repositoryURL`, тогда в About появится кнопка «Исходный код».
- [ ] **Страница плеера на лендинге Lerzo** (`/player/`) — отдельный бесплатный open-source
      плеер для macOS, без связи с подпиской приложения; в той же папке — DMG и `appcast.xml`.
- [x] Sparkle-автообновления: пакет Sparkle 2.9, `UpdaterController.swift`, пункт «Check for
      Updates…», `SUFeedURL` = `https://lerzowords.com/player/appcast.xml`, `SUPublicEDKey` в
      `build_app.sh`; `release.sh` подписывает DMG (`generate_appcast`) и пишет `dist/appcast.xml`.
- [ ] **Первый деплой обновлений**: выложить `LerzoPlayer-<v>.dmg` и `appcast.xml` в
      `https://lerzowords.com/player/` и проверить «Check for Updates…» с предыдущей версии.
- [x] Бэкап приватного ключа Sparkle — в менеджере паролей автора (восстановить в keychain:
      `.build/artifacts/sparkle/Sparkle/bin/generate_keys -i <файл>`).
- [x] Окно About (`AboutView.swift`): версия, GPLv3 (текст из `Resources/LICENSE`),
      вкладка «Библиотеки» из `THIRD-PARTY-SOURCES.md` релизной сборки, ссылка на сайт.
      Ссылка на репозиторий появится, когда `AboutInfo.repositoryURL` получит адрес.
- [ ] **Прогнать `scripts/release.sh`** после того, как бинарник стал линковаться с ffmpeg
      напрямую (модуль `Cavformat`): убедиться, что проверка «Homebrew references remain»
      проходит, и ноутаризация проходит.
      `SIGN_IDENTITY="Developer ID Application: Yurii Pustylnikov (JL43U9V85R)" NOTARY_PROFILE=VPlayer scripts/release.sh`
      (`VPlayer` — имя существующего keychain-профиля notarytool, его менять не нужно).
- [x] README: таблица горячих клавиш по `ShortcutsReference`, возможности обновлены.
- [ ] Landing/privacy policy (ключ Gemini хранится в keychain, наружу уходит только текст
      реплик в Gemini API).

## Идеи на потом

- Индикатор чтения карты субтитров — нужен только если на каком-то файле
  `SubtitleTimeline` грузится заметно долго (MKV без Cues для субтитровой дорожки).
- Список реплик / навигация по диалогу — `SubtitleTimeline` уже хранит текст всех реплик.
- `updateEmbeddedWindowOrdering` вызывается на каждом проходе layout — работает, но
  избыточно.
