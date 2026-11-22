# MTU Guard: аудит приложенного исходного архива и ручной инструмент

Дата: 2026-11-22. Проверенное вложение: `main(20261122-055015).zip`. Поставляемый ниже ручной инструмент добавлен в **локальную рабочую копию** исходников; не является опубликованным коммитом Gitea и не заменяет текущий релизный EXE.

## ВАЖНО: идентификация версии

Пользовательский отчёт относится к **0.2**, однако данный исходный ZIP фактически содержит **0.3**: `Cargo.toml=0.3.0`, `Cargo.lock=0.3.0`, `VERSION=0.3`, `CHANGELOG` и `docs/BUILD_REVIEW.md` описывают 0.3. Утверждение, что этот ZIP соответствует конкретному коммиту 0.2 `eb8bbc4`, не подтверждено; попытка получить страницу Gitea завершилась сетевым тайм-аутом. В архиве **нет** compiled `withen-mtu-guard.exe`, PDB или официального release ZIP 0.3. Поэтому binary/PE/Authenticode/SHA256 релизного файла самостоятельно проверить невозможно.

## Результаты исходного аудита

**Подтверждено чтением исходников:**

- `src/win.rs` использует `NotifyIpInterfaceChange(AF_INET)`; callback только передаёт сигнал в bounded `sync_channel(1)`. После события рабочий поток объединяет уведомления в 400 мс; fallback-проверка раз в 30 секунд. `CancelMibChangeNotify2()` выполняется отдельно от callback.
- `GetIfTable2()`/`GetIpInterfaceEntry()` для выбора и чтения, `SetIpInterfaceEntry()` для исправления, `SitePrefixLength=0` перед записью в IPv4; интерфейс переизбирается перед записью и после неё, сравнивается LUID. `set` вызывается только если MTU отличается от 1280.
- Цель — `AmneziaVPN`, `AmneziaVPN N`, включая `1`, только канонический ASCII-суффикс UInt32. Среди кандидатов выбирается один активный, виртуальный, с доступной IPv4-строкой. Несколько подходящих => `AMBIGUOUS`, без изменения сетевых параметров. Нет интерфейса => `WAITING`.
- `Windows Service` с `WithenMtuGuard`, SCM `LocalSystem`, старт/стоп; установщик проверяет UAC, целевой `ImagePath`, Automatic, ACL Program Files/ProgramData, имеет uninstall с ограничением путей.
- `.cargo/config.toml` задаёт статическую CRT; PE script отклоняет динамические VC++ DLL и неизвестные импорты. Исходники утверждают, что PE/PDB и installer проходят проверки на Windows; **независимо воспроизвести это из Linux нельзя**.
- Приложена полная лицензия Apache License 2.0, NOTICE и документация на русском. Приватных ключей/учётных данных в открытых исходниках не обнаружено.

**Проверено инструментально в текущей среде:**

- ZIP успешно открыт и распакован с проверкой путей.
- В оригинале 49 записей `SHA256SUMS_SOURCE.txt` совпадают с содержимым файлов.
- `python tests/repo_checks.py` — PASS (это структурный/static test, не Cargo).
- В локально дополненном исходном дереве 55 SHA256 записей, все совпали; `tests/manual_tool_static.py` — PASS.

**Не проводилось здесь:** `cargo test`, `cargo clippy`, Windows PE audit, выполнение установщика, реальные вызовы Windows IP Helper API и PowerShell 5.1. В текущем Linux-окружении отсутствуют Rust/MSVC/Windows. В документе `docs/BUILD_REVIEW.md` указаны 34 Rust-теста и PASS текущей Windows 11 SCM; это результаты пользователя, не независимая повторная проверка.

## Оценка и риски

Версия 0.3 выглядит подготовленной к **контролируемой полевой приёмке**, но не к безусловной публичной публикации. Очевидных новых P0/P1-проблем в просмотренной реализации службы не выявлено; это не означает доказанного отсутствия ошибок.

1. **P1 — обязательная матрица Windows 10/11:** реальное исправление `1376 → 1280`, hot restart AmneziaVPN, split tunneling On/Off/On, reboot, несколько Up/Down интерфейсов, суффикс `AmneziaVPN 2`. Тесты Rust используют модель API, а не драйвер Windows.
2. **P1 — бинарный релиз отдельно:** предоставить реальный `MTU-Guard-0.3.0-win-x64.zip` и `RELEASE_SHA256SUMS.txt` для независимого PE/CRC/SHA/manifest review; исходный ZIP не содержит этих файлов. Публикацию в Gitea/соответствие коммиту проверить отдельно.
3. **P1 — служба LocalSystem:** целевой адаптер определяется по alias/виртуальности и IPv4; это не криптографическая аттестация Wintun/Amnezia. Нельзя предоставлять непривилегированным пользователям запись в каталог установленного EXE или подмену конфигурации.
4. **P2 — последний race window:** повторная проверка LUID до `SetIpInterfaceEntry` сокращает гонку, но не делает чтение/запись атомарными при одновременном пересоздании адаптера.
5. **P2 — производительность:** event-driven + 30-секундный safety sweep подходит; короткая 5-секундная запись CPU=0 в отчёте недостаточна для заключения об одном часе. Проверить после split tunneling бурст/лог-ротацию и число записей в `guard.log`.
6. **P2 — GUI/сообщения:** WAITING и AMBIGUOUS должны быть доступны обычному пользователю без вывода нестабильных GUID/ключей VPN. Множественные названия `AmneziaVPN` **не обязательно** означают грязную установку драйвера.

## Дополнение: ручной PowerShell без установки службы

В локальный **неопубликованный** патч добавлены `tools/manual-mtu.ps1`, `manual-mtu.cmd`, `manual-check.cmd`, `docs/MANUAL_MTU.md`. `scripts/package.ps1` теперь включает их в будущие ZIP. Изменения отмечены в `CHANGELOG` как `[Unreleased]`, чтобы не приписывать их уже собранной 0.3.

- Меню `1` — read-only проверка без UAC; `2` — 1280 с UAC только при необходимости; `3` — ручной MTU 576..9000 с предупреждением; `4` — выход.
- Выводятся все подходящие по именам интерфейсы с состоянием Up/Down, ifIndex, Virtual/Hardware, IPv4, MTU, Description. Несколько записей дают предупреждение, несколько **активных пригодных** — отказ от изменения.
- Проверка MTU использует `netsh ipv4 show subinterfaces` (известный рабочий источник в тестах AmneziaVPN), с fallback через `Get-NetIPInterface`. Запись через штатный `Set-NetIPInterface -AddressFamily IPv4 -NlMtuBytes -PolicyStore ActiveStore`, без изменения других сетевых свойств. Перед/после повторно проверяются alias, индекс и GUID.
- Отдельный добровольный HTTPS-probe на 1.1.1.1; `[PASS] MTU` и `[PASS] HTTPS` не объединяются в ложную гарантию всей сети. Ничего не устанавливает в SCM и не создаёт автозапуск.
- Добавлены PowerShell 5.1 AST-проверка на Windows (пока **NOT RUN**), portable static тест и приемочные сценарии T35–T39. Проверка двух режимов на Windows обязательна до передачи пользователям.

**Осторожно:** ручной инструмент НЕ входит в оригинальный опубликованный релиз 0.3 и не проверялся на реальной Windows. Использовать сначала на тестовом ПК, лучше с запущенным VPN; корпоративные политики/Smart App Control могут запрещать неподписанные скрипты, их не нужно отключать ради обхода.

## Быстрая последовательность приёмки

1. Сборщик на Windows: `build.ps1` (включая `tests/manual-mtu.Tests.ps1`), потом `scripts/package.ps1`; сверить внешние и внутренние SHA256, binary версии, PE imports.
2. На Windows 10 x64: `manual-check.cmd` без VPN (WAITING), с VPN на 1376 (WARN/код 4); `manual-mtu.cmd` → `2` → UAC → 1280 → HTTPS. Проверить `netsh ... show subinterfaces` отдельно.
3. На Windows 11 x64: установить службу (installer PASS) и при рабочем туннеле многократно переключить split tunneling. После каждого пересоздания дождаться возвращения MTU 1280; проверить журнал и `status.cmd`.
4. Создать/найти `AmneziaVPN 2` или `AmneziaVPN 1` и неактивный исходный адаптер; не изменять физические адаптеры. При двух Up — отказ AMBIGUOUS.
5. Reboot, затем запустить AmneziaVPN; проверить автозапуск `WithenMtuGuard`, корректный MTU и HTTPS.
6. Измерить RAM, CPU delta и число записей журнала 60 минут, повторить uninstall и убедиться в отсутствии службы.

## Документация Microsoft

- [NotifyIpInterfaceChange](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-notifyipinterfacechange)
- [GetIfTable2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getiftable2)
- [SetIpInterfaceEntry](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-setipinterfaceentry)
- [CancelMibChangeNotify2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-cancelmibchangenotify2)
- [Get-NetAdapter](https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapter)
- [Set-NetIPInterface](https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-netipinterface)
- [Start-Process UAC](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1)
