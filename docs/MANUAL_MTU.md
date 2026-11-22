# Ручная проверка и исправление MTU

MTU Guard manual 0.1 — дополнительный кандидат для Windows 10/11 x64 с AmneziaVPN. Разработчик и издатель — [Flamy Studio](https://flamy.studio), заказчик — [Withen Network](https://withen.pro). Apache-2.0, файлы LICENSE и NOTICE в корне пакета.

Инструмент выполняет разовое изменение без установки службы. Для работы нужны встроенные Windows PowerShell 5.1, модули NetAdapter/NetTCPIP и .NET Framework Windows. Отдельные Rust, Visual C++ Runtime, curl и .NET Runtime не требуются.

## Запуск

Распакуйте **весь** ZIP. `manual-check.cmd` запускает проверку и удерживает окно открытым. `manual-mtu.cmd` предлагает меню:

1. Проверить адаптеры и MTU без UAC.
2. Установить IPv4 MTU 1280. UAC запрашивается, только если значение нужно изменить.
3. Задать другое MTU от 576 до 9000 для согласованного теста.
4. Выйти без проверки и изменений.

Меню отдельно предлагает добровольную HTTPS-проверку. Вывод показывает фактические имя, индекс, состояние Up, признак виртуального интерфейса, наличие запрошенной IPv4-строки, MTU и описание. GUID нужен внутренним проверкам и в обычном выводе не показывается. Для исключённых до запроса IPv4 записей выводится `not-queried`.

При нескольких записях AmneziaVPN инструмент показывает их все. Это не доказывает остатки драйвера или неисправную установку; автоматически удалять или переименовывать устройства не следует.

## Выбор и изменение

Допускаются `AmneziaVPN` и `AmneziaVPN N`, N = 1..4294967295: один ASCII-пробел, цифры без знака и ведущих нулей, регистр базового имени не важен. Нужны Up, `HardwareInterface=false` и строка IPv4. Старые неактивные экземпляры не мешают единственному подходящему.

- Подходящих нет — WAITING, без записи.
- Подходящий один — проверка его MTU; неизвестное значение запрещает изменение.
- Подходящих несколько — AMBIGUOUS, без записи и без выбора по номеру/порядку.
- Ошибка API прекращает весь выбор. Она не превращается в отсутствие кандидата.

Чтение выполняется через `Get-NetIPInterface -AddressFamily IPv4 -PolicyStore ActiveStore`. В возвращаемом CIM-объекте используется **`NlMtu`**; `NlMtuBytes` — имя параметра команды, а не этого свойства. `netsh` и локализованные текстовые таблицы для чтения не нужны.

Запись использует только `Set-NetIPInterface -NlMtuBytes ... -PolicyStore ActiveStore` с ограничением по IPv4, alias, индексу и compartment. Другие сетевые параметры в setter не передаются. Перед записью выполняется новый полный выбор и сравниваются GUID, индекс, имя и compartment; затем через 300 мс проверяются та же цель и значение MTU. Если другой процесс уже исправил значение, повторной записи нет.

Исходные GUID, индекс, имя и compartment передаются через UAC. Если интерфейс пересоздан во время подтверждения, инструмент отказывается писать. Привилегированный помощник выполняет коррекцию; исходное окно повторно проверяет результат и показывает его. Повторного UAC при отсутствии полученных прав нет. Для подробной ошибки помощника можно запустить приведённую ниже команду из PowerShell администратора.

Между последней проверкой и системной записью остаётся неатомарное окно. GUID/alias/виртуальность не удостоверяют производителя драйвера. Служба, автозапуск, маршруты, DNS, IPv6 и драйверы не настраиваются.

## Команды техподдержки

```powershell
# Только чтение, без администратора и ожидания Enter
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\manual-mtu.ps1 -Mode Check -NoPause

# Разовое исправление на 1280; UAC при необходимости
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\manual-mtu.ps1 -Mode Fix -Mtu 1280 -NoPause

# Дополнительно — добровольная HTTPS-проверка
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\manual-mtu.ps1 -Mode Check -Probe -NoPause

# Нестандартное значение для согласованного теста
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\manual-mtu.ps1 -Mode Fix -Mtu 1200 -NoPause
```

Коды: **0** — MTU подтверждён (либо выбран выход из меню без проверки), **3** — WAITING, **4** — в режиме Check MTU отличается от 1280, **1** — ошибка/неоднозначность/неподтверждённая коррекция. Режим Check всегда сравнивает с 1280. Для сценариев автоматизации используйте Check/Fix с `-NoPause`.

HTTPS обращается к Cloudflare `https://1.1.1.1/cdn-cgi/trace` через встроенный .NET HTTP-клиент, без прокси/перенаправлений. Сохраняется только HTTP-код в выводе; тело ответа с публичным IP не читается. Ошибка HTTPS даёт отдельный WARN и не изменяет код проверки MTU. PASS MTU не подтверждает доступность всех приложений.

## Ограничения и испытания

Разовое ActiveStore-изменение может сброситься после пересоздания адаптера или перезагрузки. Для постоянного поддержания MTU предусмотрена отдельная служба MTU Guard. Работающая служба будет возвращать нестандартное MTU к 1280; инструмент её не останавливает.

На текущей Windows 11 26H2 пройден 31 тест с подменёнными сетевыми командами/UAC. Дополнительно проверено реальное чтение `AmneziaVPN` с MTU 1280. HTTPS вернул 200; Fix при уже верном значении завершился без записи и UAC. Реальная коррекция 1376 → 1280, переход через UAC с записью, числовые адаптеры, неоднозначность на реальных устройствах и чистая Windows 10 остаются **NOT RUN**. Модельные тесты их не заменяют.

Пакет manual 0.1 является кандидатом для контролируемой приёмки. Подписей Authenticode нет. При блокировке корпоративной политикой или защитой Windows сообщите издателю; отключать защиту ради инструмента не нужно.

## Официальные источники

- [Microsoft: Get-NetAdapter](https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapter)
- [Microsoft: Get-NetIPInterface](https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netipinterface)
- [Microsoft: MSFT_NetIPInterface, свойство NlMtu](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/nettcpipprov/msft-netipinterface)
- [Microsoft: Set-NetIPInterface](https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-netipinterface)
- [Microsoft: Start-Process / RunAs](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1)
