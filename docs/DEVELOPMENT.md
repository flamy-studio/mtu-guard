# Разработка и техническая документация MTU Guard

Разработчик и издатель — [Flamy Studio](https://flamy.studio). Проект создан по заказу [Withen Network](https://withen.pro). Основной репозиторий — [Gitea](https://git.flamy.studio/prod/Withen_MTU_Guard).

Пользовательская установка описана в [README](../README.md). Здесь находятся сборка, диагностические команды и сведения для сопровождения проекта. Полный кандидат 0.3 и компактный ручной кандидат 0.1 пересобраны с актуальными исходниками, брендингом и документацией. Состав пакетов, текущие суммы и границы подтверждения: [BUILD_REVIEW](BUILD_REVIEW.md).

## Сборка и проверки

Требуется Windows 10/11 **x64**, актуальная стабильная Rust toolchain (`rustup`, `cargo`), MSVC build tools и Windows SDK. Требуется PowerShell 5.1 (встроен в Windows 10/11).

```powershell
# Из корня проекта на Windows:
.\build.ps1
# Скрипт запускает cargo fmt, test, clippy и release build,
# проверяет ресурсы EXE и PDB, затем копирует оба файла в корень.
# ZIP с EXE, PDB, инструкциями и SHA-256:
.\scripts\package.ps1
# Существующий архив защищён от перезаписи; для нового выпуска назначьте новую версию.
# Установку запускают отдельно, когда нужно проверить службу: .\install.cmd
```

Или вручную:

```powershell
rustup target add x86_64-pc-windows-msvc
cargo fmt --all -- --check
cargo test --locked --all-targets --target x86_64-pc-windows-msvc
cargo clippy --locked --all-targets --target x86_64-pc-windows-msvc -- -D warnings
cargo build --locked --release --target x86_64-pc-windows-msvc
.\scripts\verify-build.ps1 -BinaryPath .\target\x86_64-pc-windows-msvc\release\withen-mtu-guard.exe
```

`Cargo.lock` включён в исходники; проверки и сборка используют `--locked`. Обновление зависимостей выполняется отдельно с проверкой изменений lockfile. Это фиксирует версии зависимостей, но не гарантирует побитово одинаковый EXE на разных toolchain/SDK.

Проект размещается в Gitea на `git.flamy.studio`. Автоматическая сборка пока не настроена. Проверки и сборка доступны через `build.ps1`, упаковка — через `scripts/package.ps1`. Публикация релиза выполняется оператором после приёмки.

### Ресурсы и release-профиль

`build.rs` через `winresource` вшивает `favicon.ico`, описание, название **MTU Guard**, компанию **Flamy Studio**, версии из Cargo и manifest. `asInvoker` позволяет читать `status` без UAC; команду `fix` запускают из повышенного терминала, а службу — через SCM. Технические имя EXE `withen-mtu-guard.exe`, имя службы `WithenMtuGuard` и каталоги `WITHEN\MTU Guard` сохранены для совместимости установки.

Release-профиль использует `lto=true`, `debug=true`, `strip="none"`. На MSVC отладочная информация сохраняется в `withen_mtu_guard.pdb`; упаковщик переносит PDB вместе с EXE. UPX и другие упаковщики EXE не применяются; обычный ZIP сжимает файлы для доставки и не меняет структуру EXE.

`.cargo/config.toml` задаёт `-C target-feature=+crt-static`. Этот каталог обязателен для сборки: `build.rs` отклонит MSVC-сборку без статической CRT. `verify-build.ps1` читает обычные и отложенные PE-импорты и отклоняет VC++/UCRT и сторонние DLL. `build.ps1` также проверяет положительные и отрицательные PE-примеры, ожидание MTU в установщике, разбор статуса с числовыми именами/ошибками и ручной инструмент.

Ресурсы, LTO и PDB не гарантируют отсутствие антивирусных срабатываний. Поле `CompanyName` — сведения о продукте, а проверенный издатель в UAC/SmartScreen зависит от цифровой подписи и репутации. Authenticode-подпись в эту сборку не добавлена. См. [проверку по официальным источникам](BUILD_REVIEW.md).

## Отдельный ручной пакет

Ручной инструмент работает на встроенных Windows PowerShell 5.1 и .NET Windows без Rust EXE. Его пользовательские команды и ограничения: [MANUAL_MTU](MANUAL_MTU.md).

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\manual-mtu.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-manual.ps1
```

Полный `build.ps1` запускает 34 Rust-теста и PowerShell-наборы, включая 31 поведенческий тест ручного инструмента, затем Clippy, release и проверку PE/ресурсов/PDB. В поведенческих тестах ручного инструмента сеть, UAC и ожидания подменены. Реальные полевые сценарии отмечены отдельно в [TESTING](TESTING.md).

`package.ps1` и `package-manual.ps1` отказываются заменять существующий архив без `-Overwrite`. Используйте новую версию для следующего выпуска; явная перезапись допустима для локального кандидата. EXE/PDB/ZIP и локальные журналы исключены из Git.

## Диагностические команды и коды выхода

```powershell
# Из каталога с exe — без администратора, только чтение:
.\withen-mtu-guard.exe status

# Разовое применение, от администратора:
.\withen-mtu-guard.exe fix

# Сервис управляется SCM:
Get-Service WithenMtuGuard
sc.exe query WithenMtuGuard

# Лог:
Get-Content "$env:ProgramData\WITHEN\MTU Guard\guard.log" -Tail 30
```

Состояния: `PASS` — IPv4 MTU равен 1280; `WAITING` — подходящего активного IPv4-интерфейса пока нет; `WARN` — значение иное при диагностике без исправления; `FAIL` — ошибка Windows API, неоднозначный адаптер или отказ проверки. **PASS MTU не равнозначен доказательству работы зарубежного HTTPS** — это отдельный тест.

`status` оставляет код 0 для информационных состояний `WAITING`/`WARN`. Для автоматической проверки используйте `check`: **0** — MTU 1280, **3** — интерфейс отсутствует/инициализируется, **4** — MTU отличается, **1** — ошибка API или неоднозначность; неизвестная команда возвращает **2**. При WAITING выводятся найденные Amnezia-имена с состоянием, признаком hardware и описанием. Вывод и сборщик наблюдений сохраняют фактическое имя, включая регистр и суффикс.

## Наблюдавшаяся проблема и назначение исправления

На некоторых ПК AmneziaVPN 5.1.0.6 создаёт адаптер `AmneziaVPN` с IPv4 MTU **1376**, несмотря на то что профиль WITHEN/WRE требует **1280**. В испытаниях 21 ноября 2026 года это сопровождалось тайм-аутами зарубежного HTTPS при рабочем DNS и российском трафике. Ручная команда `netsh interface ipv4 set subinterface "AmneziaVPN" mtu=1280 store=active` восстанавливала HTTPS (`200 OK`, зарубежный egress через Exit) на двух независимых ПК; при перезагрузке или пересоздании интерфейса AmneziaVPN могла вернуть 1376. Это основание для автоматического, но **узко ограниченного** исправления.

## Структура

```text
src/
  main.rs             # команды CLI
  policy.rs           # чистая логика и unit-тесты
  win.rs              # IP Helper API, Windows Service, watcher
  win/tests.rs        # модель API: неоднозначность, исчезновение, смена LUID
build.rs              # Windows VERSIONINFO, иконка, manifest
app.manifest          # asInvoker, Windows 10/11
favicon.ico           # иконка приложения
Cargo.lock            # фиксированные версии зависимостей
.cargo/config.toml    # статическая CRT для MSVC x64
scripts/
  install.ps1         # UAC/ACL/SCM, установка и обновление
  uninstall.ps1       # удаление SCM/файлов
  verify-build.ps1    # проверка x64 PE, DLL, метаданных, иконки, manifest и PDB
  service-common.ps1  # безопасные пути и ожидание MTU
  collect-evidence.ps1 # имя, MTU, LUID, ifIndex, CPU/RAM для полевых тестов
  status-parser.ps1   # разбор фактического имени и фиксация ошибок CLI
  package.ps1         # полный ZIP и SHA-256
  package-manual.ps1  # отдельный ручной кандидат
tools/
  manual-mtu.ps1      # меню и CLI ручного инструмента
  manual-common.ps1   # выбор, чтение/запись и UAC
install.cmd           # двойной клик
uninstall.cmd
status.cmd
manual-mtu.cmd
manual-check.cmd
docs/
  DEVELOPMENT.md
  ARCHITECTURE.md
  TESTING.md
  SECURITY.md
  RELEASE.md
```

## Ограничения

- Поддерживается только Windows 10/11 x64; ARM64 и Windows 7/8 не являются целями 0.3.
- Разрешены только `AmneziaVPN` и `AmneziaVPN N` по правилам выше. Произвольно переименованный или локализованный интерфейс не выбирается. Флаг hardware исключает физические адаптеры; имя и описание не удостоверяют принадлежность устройства AmneziaVPN. Описание сохраняется для диагностики, без жёсткого списка названий драйверов. См. [NET-002](NET-002.md).
- Интерфейс может пересоздаваться при старте и после входа пользователя; служба переживает это благодаря перепоиску и fallback-проверке.
- Текущий режим распространяется **только на IPv4 MTU**, потому что WRE в проверенной конфигурации не предоставляет клиентский IPv6-трафик как выход в Интернет.
- Временная race-ситуация между Amnezia и службой возможна; нет формальной гарантии нулевого окна с MTU 1376. Программа не вмешивается в жизненный цикл клиента.
- Нужны административные права для установки и корректировки интерфейса. Сама служба работает как LocalSystem; это повышенная привилегия, см. [SECURITY](SECURITY.md).

## Отношение к WRE Harness

Это отдельная клиентская утилита, а не компонент WRE Hub/Exit. На WRE 0.9 можно независимо рассмотреть MSS clamping как **дополнительную защиту TCP**, но он не устраняет неправильный MTU Windows-интерфейса и не решает проблемы крупных UDP-пакетов. Техническое заключение выдаётся отдельным документом.

## Навигация

- [Архитектура и контракты Windows API](ARCHITECTURE.md)
- [Выбор интерфейса и числовые суффиксы](NET-002.md)
- [Модель доверия и безопасность](SECURITY.md)
- [Матрица проверок](TESTING.md) и [полевые команды](FIELD_TESTS.md)
- [Процедура выпуска](RELEASE.md)
- [Отчёт сборки 0.3](BUILD_REVIEW.md) и [исторический отчёт 0.2](BUILD_REVIEW_0.2.md)
- [Закрытие замечаний 0.2](AUDIT_0.2.md)
- [Интеграция ручного инструмента и внешнего аудита](MANUAL_INTEGRATION.md)
- [Правила участия](../CONTRIBUTING.md), [история изменений](../CHANGELOG.md)

## Источники API

- [Microsoft: NotifyIpInterfaceChange](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-notifyipinterfacechange)
- [Microsoft: GetIpInterfaceEntry](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getipinterfaceentry)
- [Microsoft: SetIpInterfaceEntry](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-setipinterfaceentry)
- [Microsoft: GetIfTable2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getiftable2)
- [Microsoft: Windows services](https://learn.microsoft.com/en-us/windows/win32/services/service-entry-point)
