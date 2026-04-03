# Host-Level AmneziaWG -> sing-box -> Hysteria2

Этот каталог теперь содержит хостовый пакет для российской точки входа:

- клиент подключается к российскому серверу через host-level `AmneziaWG`;
- `sing-box` работает на хосте как `systemd`-сервис;
- `entrypoint.sh` настраивает `TPROXY`, `ip rule` и `nftables` прямо в host namespace;
- домены в зонах `.ru` и `.рф` отправляются напрямую;
- остальной трафик уходит на зарубежный `Hysteria 2`.

Схема:

```text
Client -> AmneziaWG (host) -> TPROXY -> sing-box -> direct (.ru/.рф)
                                             -> hysteria2 (everything else)
```

## Что входит

- `install_router.sh` - читает параметры из `.env` или `--env-file`, генерирует `sing-box` конфиг, runtime env и `systemd` unit
- `entrypoint.sh` - настраивает `TPROXY` и запускает `sing-box` на хосте
- `remove_router.sh` - останавливает и удаляет `systemd`-сервис
- `status_router.sh` - показывает состояние сервиса, `ip rule`, `nftables` и последние логи
- `debug_router.sh` - собирает полный диагностический bundle в лог-файл
- `.env.example` - шаблон переменных без секретов

## Что этот пакет не делает

- не устанавливает и не конфигурирует сам host-level `AmneziaWG` интерфейс;
- не генерирует AWG-конфиг;
- не строит полную geosite/geoip-маршрутизацию.

Он предполагает, что на сервере уже есть или скоро появится интерфейс `awg*`/`wg*`.

## Требования

- Ubuntu/Debian сервер
- root-доступ
- рабочий `HY2_URI` для зарубежного `Hysteria 2`
- host-level `AmneziaWG` или `WireGuard`-совместимый интерфейс `awg*`/`wg*`
- пакеты `iproute2`, `nftables`, `systemd`
- `sing-box` на хосте

Если `sing-box` ещё не установлен, можно дать инсталлятору поставить его через apt:

```bash
sudo INSTALL_PACKAGES=1 bash install_router.sh
```

## Быстрый старт

На российском сервере:

```bash
cd router
chmod +x install_router.sh remove_router.sh status_router.sh entrypoint.sh
cp .env.example .env
$EDITOR .env
sudo bash install_router.sh
```

Или с отдельным env-файлом:

```bash
sudo bash install_router.sh --env-file /root/hp2-router.env
```

После запуска скрипт:

- определит host интерфейс `awg*`/`wg*`, если `AWG_IFACE` не задан явно;
- если интерфейс ещё не поднят, возьмёт fallback `awg0` и поставит сервис в ожидание;
- сгенерирует `sing-box` конфиг в `/opt/hp2-router/config/config.json`;
- запишет runtime env в `/opt/hp2-router/service.env`;
- скопирует `entrypoint.sh` в `/opt/hp2-router/bin/router-entrypoint.sh`;
- создаст unit `/etc/systemd/system/hp2-router.service`;
- выполнит `sing-box check` и запустит сервис.

`config.json` содержит секреты `Hysteria 2` и создается с правами `0600`.
Полный env со значениями по умолчанию не сохраняется, если не включать `SAVE_STATE_ENV=1`.
Инсталлятор пишет лог в `/opt/hp2-router/logs/install.log`.

## Host-level AWG

Самый практичный вариант - поднять `AmneziaWG` как обычный системный интерфейс, а не через GUI self-hosted Docker install.

Обычно это означает:

- установить `amneziawg-tools` или другой совместимый toolkit;
- положить конфиг в `/etc/amnezia/amnezia-awg.conf` или аналогичный путь;
- поднимать интерфейс через `awg-quick up awg0` либо systemd unit для AWG;
- убедиться, что на хосте появляется `awg0`.

Этот пакет начинает работать после того, как интерфейс существует или когда вы явно задаёте `AWG_IFACE`.

## Дополнительные параметры

Пример:

```bash
sudo \
  SERVICE_NAME='hp2-router' \
  AWG_IFACE='awg0' \
  DIRECT_SUFFIXES='ru,xn--p1ai' \
  EXTRA_DIRECT_DOMAINS='gosuslugi.ru,ya.ru' \
  EXTRA_DIRECT_SUFFIXES='yandex.ru' \
  bash install_router.sh
```

Описание:

- `HY2_URI` - URI второго хопа `Hysteria 2`
- `INPUT_ENV_FILE` - путь к env-файлу, если не используете `--env-file`
- `SERVICE_NAME` - имя `systemd`-сервиса, по умолчанию `hp2-router`
- `AWG_IFACE` - host interface `awg*`/`wg*`
- `DEFAULT_AWG_IFACE` - fallback имя интерфейса, если host-level AWG ещё не поднят
- `DNS_SERVER` - upstream DNS сервер для `sing-box`
- `DNS_SERVER_PORT` - порт upstream DNS
- `DNS_STRATEGY` - стратегия DNS (`prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only`)
- `DEBUG_SOCKS_PORT` - временный SOCKS inbound для отладки `hy2-out`
- `INSTALL_PACKAGES=1` - установить `sing-box` и `nftables` через apt
- `DIRECT_SUFFIXES` - доменные suffixes, которые идут напрямую
- `EXTRA_DIRECT_DOMAINS` - точные домены, которые всегда идут напрямую
- `EXTRA_DIRECT_SUFFIXES` - дополнительные suffixes для прямого маршрута
- `SAVE_STATE_ENV=1` - сохранить эффективные параметры в `/opt/hp2-router/router.env`

Если `AWG_IFACE` задан явно, но интерфейс пока не поднят, install не падает. Сервис подождёт его появления до `WAIT_TIMEOUT`.
Если `AWG_IFACE` не задан и интерфейс не найден, installer использует `DEFAULT_AWG_IFACE=awg0`.

## Формат `.env`

Минимальный пример:

```bash
HY2_URI='hy2://password@example.com:443/?sni=example.com&obfs=salamander&obfs-password=secret'
```

Полный пример смотрите в `.env.example`.

## Проверка

```bash
sudo bash status_router.sh
sudo bash debug_router.sh
systemctl status hp2-router.service --no-pager
journalctl -u hp2-router.service -f
```

Если нужно посмотреть конфиг:

```bash
sudo sed -n '1,240p' /opt/hp2-router/config/config.json
```

## Удаление

Удалить сервис, unit и правила:

```bash
sudo bash remove_router.sh
```

Удалить ещё и каталог конфигурации:

```bash
sudo PURGE_CONFIG=1 bash remove_router.sh
```

## Как это работает

`entrypoint.sh` на хосте:

- ждёт появления интерфейса `awg*`/`wg*`;
- включает `ip_forward`, отключает `rp_filter` и включает `src_valid_mark`;
- создаёт `ip rule` и `local route` для `fwmark`;
- перехватывает DNS (`53/tcp`, `53/udp`) до проверки RFC1918, чтобы DNS внутри VPN тоже шёл в `sing-box`;
- создаёт `nftables` `TPROXY` rule со `counter`, чтобы по `status_router.sh` было видно реальный трафик;
- пишет стартовую диагностику: `sing-box version`, `sysctl`, `ip rule`, `route table`, `nft`;
- запускает `sing-box`.

`sing-box`:

- перехватывает TCP/UDP через `tproxy`;
- sniff'ит протоколы;
- DNS hijack матчится по `protocol=dns` или `port=53`;
- использует явный upstream DNS;
- отправляет `.ru` и `.рф` напрямую;
- всё остальное отправляет в `Hysteria 2`.

## Отладка второго хопа

Если нужно проверить `hy2-out` отдельно от `TPROXY`, включите временный SOCKS inbound:

```bash
echo "DEBUG_SOCKS_PORT='1080'" >> .env
sudo bash install_router.sh
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org --max-time 15
```

Если этот запрос работает, значит `hy2-out` исправен, а проблема остаётся в transparent-routing логике.

## Логи и отладка

Основные места:

- install log: `/opt/hp2-router/logs/install.log`
- runtime log: `journalctl -u hp2-router.service -f`
- быстрый статус: `sudo bash status_router.sh`
- полный bundle: `sudo bash debug_router.sh`

`debug_router.sh` сохраняет snapshot в `/opt/hp2-router/logs/debug-YYYYmmdd-HHMMSS.log`.

## Что стоит улучшить позже

- заменить suffix-only роутинг на полноценные `rule_set` для российских сервисов;
- добавить healthcheck для маршрутизации;
- автоматизировать раскладку host-level `AmneziaWG` конфигурации рядом с этим пакетом.
