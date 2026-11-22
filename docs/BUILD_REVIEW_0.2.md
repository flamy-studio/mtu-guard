# Проверка сборки MTU Guard 0.2

Дата: 21.11.2026. Разработчик и издатель: [Flamy Studio](https://flamy.studio). Заказчик: [Withen Network](https://withen.pro). Лицензия исходников — Apache-2.0.

## Результат

**Кандидат 0.2.0 собран и проверен на текущей Windows 11.** Зависимость от отдельно устанавливаемого Visual C++ Runtime устранена. Полевая приёмка чистых Windows 10/11, split tunneling и перезагрузки передаётся тестировщикам; результат этих сценариев пока NOT RUN.

Среда: Windows 11 26H2 (26300.9974), Rust/Cargo 1.100.0, MSVC Build Tools 2022 (14.44.35207), Windows SDK 10.0.26100.0. Это ПК со средствами разработки и восемью зарегистрированными пакетами VC++ Runtime; он не считается чистой Windows.

## Выполненные проверки

| Проверка | Фактический результат |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo test --locked --all-targets --target x86_64-pc-windows-msvc` | PASS, 10 тестов |
| `cargo clippy --locked --all-targets --target x86_64-pc-windows-msvc -- -D warnings` | PASS |
| Release MSVC x64 со статической CRT | PASS |
| Метаданные, встроенная иконка, manifest и PDB | PASS; MTU Guard / flamy.studio / 0.2.0 |
| PE-проверка обычных и отложенных импортов | PASS, только DLL Windows |
| Отрицательные тесты PE-проверки | Динамическая CRT, отложенная CRT, неизвестная DLL и ошибочный RVA отклонены |
| Проверки установщика без прав администратора | WAITING не выдаётся за успех MTU; ожидается сходимость; timeout и junction отклонены |
| `--help`, `--version`, `status`, `check` | PASS; текущий MTU 1280, `check` вернул 0 |
| Сборщик наблюдений | PASS, структурированные MTU/LUID/ifIndex; асинхронная HTTPS-проба на текущем соединении вернула 200 |
| Установка/повторная установка/остановка/удаление SCM | PASS на текущей Windows 11 после UAC |
| ZIP, CRC и SHA-256 файлов | PASS, проверены все файлы финального пакета |

Все Cargo-команды использовали `--locked`. Конфигурация `.cargo/config.toml` задаёт `-C target-feature=+crt-static`; `build.rs` запрещает MSVC-сборку без этой возможности. Проверка конечного PE не зависит от наличия VC++ Runtime на builder.

## Автономность EXE

В обычных и отложенных таблицах импорта остались только:

- `advapi32.dll`
- `api-ms-win-core-synch-l1-2-0.dll`
- `iphlpapi.dll`
- `kernel32.dll`
- `ntdll.dll`

`VCRUNTIME140.dll`, `MSVCP*.dll`, динамическая UCRT и сторонние библиотеки не импортируются. CRT и зависимости Rust включены в EXE. Для запуска нужны системные компоненты Windows; Rust, SDK и VC++ Redistributable устанавливать не требуется. PowerShell 5.1 используется только скриптами установки/диагностики и встроен в поддерживаемые Windows.

EXE: **286 208 байт**, PDB: **5 083 136 байт**. SHA-256:

- EXE: `e09a9d699252f8c7c55daf32607d6a947a342bc174cc6f9bdf3df8113871973f`
- PDB: `83c43264e98544ae201e0b4ad0349aae72d24c12e4b1ae8f7ad8c329c0536180`

Статус Authenticode: **NotSigned**. Компания в VERSIONINFO не заменяет подпись; цифровая подпись для публичного выпуска остаётся отдельным этапом.

## Реальный тест SCM

Из локального пакета выполнен `tests/windows-integration.ps1`. Перед тестом установки MTU Guard не было; после теста служба, её каталог и журналы удалены.

Подтверждены путь `"C:\Program Files\WITHEN\MTU Guard\withen-mtu-guard.exe" service`, режим Auto, LocalSystem, работа из пути с пробелами, защищённые ACL, два цикла остановки/запуска, повторная установка поверх работающей службы и повторное удаление. Проверялась повторная установка 0.2 поверх 0.2; отдельная миграция установленной 0.1 не заявляется.

Окончательный SCM-тест выполнен 21.11.2026 в 22:47 UTC после исправления ограниченного ожидания остановки. Две остановки заняли **0,008 и 0,253 секунды**. За короткую выборку **5,004 секунды** накопленное CPU-время не изменилось в пределах точности измерения; working set — 6 254 592 байт, private bytes — 1 146 880 байт. Это не заменяет часовой тест нагрузки и не доказывает буквальный «Zero CPU».

До и во время теста AmneziaVPN уже имел MTU 1280. Намеренно устанавливать 1376, переключать VPN или перезагружать рабочий ПК тест не пытался. Поэтому запись MTU, восстановление после пересоздания адаптера и холодного старта остаются полевыми сценариями.

Локальные исходные протоколы: `target/review/scm-0.2.json`, `scm-0.2-transcript.txt`, `scm-0.2.json.guard.log` и `runtime-0.2.json`. Персональные заголовки транскрипта в пользовательский пакет не включаются.

## Источники

- [Rust: статическая и динамическая CRT](https://doc.rust-lang.org/reference/linkage.html#static-and-dynamic-c-runtimes)
- [Microsoft: PE, таблицы обычных и отложенных импортов](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)
- [Microsoft: New-Service и BinaryPathName](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/new-service?view=powershell-5.1)
- [Microsoft: Win32_Service.Change](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/change-method-in-class-win32-service)
- [Microsoft: SetIpInterfaceEntry](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-setipinterfaceentry)
- [Microsoft: NotifyIpInterfaceChange](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-notifyipinterfacechange)
- [Microsoft: Smart App Control FAQ](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions)

Закрытие замечаний: [AUDIT_0.2.md](AUDIT_0.2.md). План приёмки: [TESTING.md](TESTING.md). Команды тестировщику: [FIELD_TESTS.md](FIELD_TESTS.md).
