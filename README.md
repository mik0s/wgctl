# wgctl

`wgctl` — утилита на Bash для Linux-хостов, которая выпускает клиентские WireGuard-профили, хранит метаданные, отправляет конфиги по почте и показывает активность для нескольких WireGuard-серверов/интерфейсов.

## Текущие возможности

- Создание клиентского профиля с генерацией ключей или с использованием переданного публичного ключа
- Автоматическая выдача клиентских адресов из IPv4-пула, заданного для сервера
- Сборка клиентского `.conf`
- Генерация PNG QR-кода для мобильных клиентов
- Отправка конфига и QR-кода письмом через `sendmail`
- Добавление и удаление peer на выбранном WireGuard-интерфейсе
- Управление состоянием серверных WireGuard-интерфейсов
- Просмотр raw peer и логов серверного интерфейса
- Просмотр, показ и удаление выданных профилей
- Просмотр текущей активности через `wg show <interface> dump`

## Зависимости

Установите необходимые пакеты в вашей системе. Пример для Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y wireguard-tools qrencode mailutils
```

Если почта отправляется через Postfix или msmtp, убедитесь, что по пути из `SMTP_SENDMAIL` доступен совместимый с `sendmail` бинарник.

Можно установить зависимости автоматически:

```bash
make deps
```

Если автоопределение пакетного менеджера не подходит, используйте целевой таргет, например `make deps-debian`.

## Установка

По умолчанию `wgctl` устанавливается в `/opt/wgctl`, а симлинк команды создается в `/usr/local/bin/wgctl`.

При установке по умолчанию используются:

- владелец и группа: `root:root`
- права на каталоги `PREFIX` и `config`: `0755`
- права на каталог `data`: `0750`
- права на `wgctl.sh`: `0755`
- права на `wgctl.conf` и `wgctl.conf.example`: `0640`

Во время работы `wgctl` создает каталоги `profiles` и `artifacts` с правами `0750`, а файлы профилей, конфиги, QR-коды и peer snippets с правами `0640`.

```bash
make install
```

Переопределить пути можно так:

```bash
make install PREFIX=/srv/wgctl BIN_DIR=/usr/local/bin
```

Переопределить владельца, группу и режимы можно так:

```bash
make install OWNER=wgctl GROUP=wgctl CONFIG_MODE=0640 DATA_DIR_MODE=0750
```

Удаление установленного скрипта:

```bash
make uninstall
```

`make uninstall` удаляет только установленный скрипт, пример конфига и симлинк команды. Рабочий конфиг `wgctl.conf` и каталог `data/` сохраняются.

## Конфигурация

Скопируйте пример конфига и отредактируйте значения:

```bash
mkdir -p config
cp config/wgctl.conf.example config/wgctl.conf
```

Поля:

- `SERVERS`: список идентификаторов серверов через пробел, например `main backup`
- `DEFAULT_SERVER`: необязательный идентификатор сервера по умолчанию, если `--server` не передан
- `MAIL_FROM`: глобальный адрес отправителя для писем с профилями
- `SMTP_SENDMAIL`: глобальный путь до `sendmail`-совместимого бинарника
- `SERVER_<ID>_INTERFACE`: WireGuard-интерфейс на сервере, например `wg0`
- `SERVER_<ID>_ENDPOINT`: публичный endpoint, который попадет в клиентский конфиг
- `SERVER_<ID>_SERVER_PUBLIC_KEY`: публичный ключ сервера для клиентского конфига
- `SERVER_<ID>_ALLOWED_IPS`: маршруты, которые получит клиент
- `SERVER_<ID>_ADDRESS_POOL`: IPv4-сеть для автоматической выдачи адресов, например `10.10.0.0/24`
- `SERVER_<ID>_CLIENT_PREFIX`: префикс, который будет использоваться в выдаваемых клиентам адресах, обычно `32`
- `SERVER_<ID>_POOL_FIRST_HOST`: первый host offset внутри пула, который можно выдавать, обычно `2`
- `SERVER_<ID>_POOL_LAST_HOST`: последний host offset внутри пула, который можно выдавать
- `SERVER_<ID>_DNS`: DNS-серверы, которые будут записаны в клиентский конфиг
- `SERVER_<ID>_PERSISTENT_KEEPALIVE`: значение keepalive для roaming-клиентов
- `SERVER_<ID>_APPLY_CHANGES`: если `true`, `create` добавляет peer в live-интерфейс, а `delete` удаляет его
- `SERVER_<ID>_PERSIST_CHANGES`: если `true`, после изменений текущее состояние интерфейса сохраняется в `SERVER_<ID>_SERVER_CONFIG`
- `SERVER_<ID>_SERVER_CONFIG`: путь до серверного WireGuard-конфига, используемого для сохранения состояния
- `SERVER_<ID>_PROFILE_STORE`: директория для хранения метаданных профилей этого сервера
- `SERVER_<ID>_ARTIFACT_STORE`: директория для конфигов, QR-кодов и peer snippets этого сервера

`<ID>` — это идентификатор из `SERVERS` в верхнем регистре. Например, для `main` используются переменные `SERVER_MAIN_*`.

Если в конфиге указаны относительные пути, они вычисляются относительно каталога, в котором лежит `wgctl.conf`. Для установленного варианта в `/opt/wgctl` удобно использовать `../data/...`, чтобы данные попадали в `/opt/wgctl/data/...`.

## Использование

Показать список настроенных серверов:

```bash
./wgctl.sh server list
```

Если задан `DEFAULT_SERVER`, параметр `--server` можно не указывать — будет выбран сервер по умолчанию.

Если `SERVER_<ID>_APPLY_CHANGES=true`, команды `create` и `delete` сразу меняют live-интерфейс выбранного сервера. `create --dry-run` не отправляет письмо и не трогает интерфейс.

Создать профиль и отправить его по почте:

```bash
./wgctl.sh create alice --email alice@example.com
```

Создать профиль без отправки письма:

```bash
./wgctl.sh create alice --email alice@example.com --dry-run
```

Создать профиль, если у клиента уже есть ключевая пара:

```bash
./wgctl.sh create alice --email alice@example.com --public-key CLIENT_PUBLIC_KEY
```

В этом режиме в клиентский конфиг не записывается `PrivateKey`. Это подходит только для сценария, где приватный ключ подставляется на стороне клиента. Если приватный ключ тоже известен, можно передать оба:

```bash
./wgctl.sh create alice --email alice@example.com --public-key CLIENT_PUBLIC_KEY --private-key CLIENT_PRIVATE_KEY
```

При необходимости можно вручную переопределить автоматически выбранный адрес:

```bash
./wgctl.sh create alice --email alice@example.com --address 10.10.0.50/32
```

Показать выданные профили:

```bash
./wgctl.sh list
```

Показать один профиль:

```bash
./wgctl.sh show alice
```

Удалить профиль:

```bash
./wgctl.sh delete alice
```

Показать активность для всех известных peer:

```bash
./wgctl.sh activity
```

`activity` показывает только те peer, которые известны локальной базе `wgctl`, и выводит имя профиля вместо публичного ключа.

Показать активность для одного профиля:

```bash
./wgctl.sh activity alice
```

Показать настройки одного сервера:

```bash
./wgctl.sh server show public
```

Показать состояние сервера по умолчанию:

```bash
./wgctl.sh server status
```

Поднять, остановить или перезагрузить интерфейс:

```bash
./wgctl.sh server up public
./wgctl.sh server down public
./wgctl.sh server reload public
```

Подтянуть все профили из локальной базы в live-интерфейс:

```bash
./wgctl.sh server sync public
```

Это полезно после перезапуска интерфейса или если peer есть в локальной базе `wgctl`, но отсутствуют в `wg0`/`wg1`.

Показать текущие peer на серверном интерфейсе:

```bash
./wgctl.sh server peers public
```

`server peers` показывает raw peer непосредственно из интерфейса WireGuard, включая те, которых может не быть в локальной базе `wgctl`.

Показать последние логи интерфейса:

```bash
./wgctl.sh server logs public
```

## Что хранится

Для каждого выданного профиля утилита сохраняет файлы в директории, настроенные для выбранного сервера:

- метаданные профиля в `<PROFILE_STORE>/<name>.env`
- клиентский конфиг в `<ARTIFACT_STORE>/<name>.conf`
- QR-код в `<ARTIFACT_STORE>/<name>.png`
- server peer snippet в `<ARTIFACT_STORE>/<name>.peer.conf`

При стандартной установке через `make install` структура обычно такая:

```text
/opt/wgctl/
  wgctl.sh
  config/
    wgctl.conf
    wgctl.conf.example
  data/
    <server-id>/
      profiles/
        <name>.env
      artifacts/
        <name>.conf
        <name>.png
        <name>.peer.conf
```

Server peer snippet можно вручную добавить в серверный WireGuard-конфиг или использовать в последующей автоматизации.

Если `SERVER_<ID>_PERSIST_CHANGES=true`, после добавления или удаления peer текущий вывод `wg showconf <interface>` записывается в `SERVER_<ID>_SERVER_CONFIG`.

## Ограничения

- Автоматическая выдача адресов сейчас поддерживает только IPv4-пулы
- Активность видна только для peer, которые сейчас присутствуют на выбранном серверном интерфейсе
- Для live-изменений нужны права на выполнение `wg set` и, если включено сохранение, на запись в `SERVER_<ID>_SERVER_CONFIG`
