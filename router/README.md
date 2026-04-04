# AmneziaWG Bootstrap With wiresock/amneziawg-install

Этот каталог теперь содержит bootstrap-пакет для **чистого сервера** и отдельный routing-layer поверх уже поднятого `AWG`.

Он больше не использует старую docker-sidecar схему с `TPROXY`, `sing-box` и миграцией из dockerized `Amnezia`.
Вместо этого bootstrap опирается на [`wiresock/amneziawg-install`](https://github.com/wiresock/amneziawg-install) и поднимает:

- `AmneziaWG` на сервере;
- веб-панель через `amneziawg-web.sh install`.
- отдельный host-level routing layer через `sing-box tun + auto_route/auto_redirect + Hysteria2`.

## Что входит

- `install_awg_stack.sh` - основной installer для нового чистого сервера
- `status_awg_stack.sh` - быстрый статус для `AmneziaWG` и панели
- `install_awg_routing.sh` - companion installer для маршрутизации `.ru` напрямую и остального трафика через `Hysteria2`
- `status_awg_routing.sh` - быстрый статус routing-сервиса
- `awg-routing-entrypoint.sh` - runtime-логика для host-level `sing-box`, sysctl и runtime-диагностики
- `render_awg_routing_config.sh` - отдельный builder, который собирает итоговый `sing-box` config из `.env`, manual lists и generated lists
- `update_blocked_domains.sh` - отдельный updater, который читает `blocked_services.txt`, скачивает exact/wildcard domains из `iplist`, обновляет generated blocklist и при изменениях перерендеривает config
- `config/domains/blocked_domains.txt` - ручной exact-list доменов через `hy2-out`
- `config/domains/blocked_suffixes.txt` - ручной suffix-list доменов через `hy2-out`
- `config/domains/blocked_services.txt` - список сервисов, для которых нужно скачать полный набор доменов из `iplist`
- `config/domains/iplist_groups.tsv` - mapping `local service -> iplist group`
- `.env.example` - шаблон переменных для неинтерактивного запуска

## Что делает installer

`install_awg_stack.sh`:

1. ставит bootstrap-зависимости (`git`, `curl`, `ca-certificates`), если это включено;
2. ставит зависимости для сборки панели (`build-essential`, `pkg-config`, `libssl-dev`) и `Rust/cargo`, если панель включена;
3. клонирует или обновляет `wiresock/amneziawg-install`;
4. запускает `amneziawg-install.sh`;
5. поднимает веб-панель через `amneziawg-web.sh install`;
6. пишет лог установки в `/opt/hp2-awg-stack/logs/install.log`;
7. сохраняет state-файл в `/opt/hp2-awg-stack/stack.env`.

## Быстрый старт

На новом сервере:

```bash
cd router
chmod +x install_awg_stack.sh status_awg_stack.sh
cp .env.example .env
$EDITOR .env
sudo bash install_awg_stack.sh
```

Если хотите использовать отдельный env-файл:

```bash
sudo bash install_awg_stack.sh --env-file /root/hp2-awg-stack.env
```

## Режимы работы

По умолчанию:

- `AUTO_INSTALL='y'`
- `SERVER_AWG_NIC='awg0'`
- панель ставится автоматически
- панель слушает `127.0.0.1:8080`

Это соответствует рекомендуемому стартовому режиму из репозитория и статьи.

## Основные переменные

- `STACK_WORK_DIR` - рабочий каталог checkout/logs/state
- `WIRESOCK_REF` - ветка или tag репозитория
- `INSTALL_DEPENDENCIES=1` - ставить bootstrap-зависимости через apt
- `INSTALL_WEB_PANEL=1` - ставить панель
- `INSTALL_WEB_RUST=1` - автоматически ставить `rustup/cargo` для панели
- `AUTO_INSTALL=y` - запускать `amneziawg-install.sh` в неинтерактивном режиме
- `SERVER_PUB_IP` - публичный IP сервера
- `SERVER_PUB_NIC` - внешний интерфейс сервера
- `SERVER_AWG_NIC` - имя AWG интерфейса, обычно `awg0`
- `SERVER_AWG_IPV4` - IPv4 сети VPN
- `SERVER_AWG_IPV6` - IPv6 сети VPN
- `SERVER_PORT` - UDP порт сервера
- `CLIENT_DNS_1`, `CLIENT_DNS_2` - DNS для клиентов
- `ALLOWED_IPS` - allowed IPs в клиентских конфигах; для текущего routing-layer по умолчанию только `0.0.0.0/0`
- `AWG_WEB_LISTEN` - адрес панели, по умолчанию `127.0.0.1:8080`
- `AWG_WEB_PUBLIC_BASE_URL` - внешний URL панели, если он нужен
- `DNS_STRATEGY=ipv4_only` - рекомендуемый режим для transparent routing через `AWG`, чтобы клиент не зависал на IPv6

## Проверка

```bash
sudo bash status_awg_stack.sh
```

Дополнительно:

```bash
journalctl -u awg-quick@awg0.service -f
cd /opt/hp2-awg-stack/amneziawg-install && ./amneziawg-web.sh status
ss -ltnp | grep 8080 || true
```

## Логи

- install log: `/opt/hp2-awg-stack/logs/install.log`
- state file: `/opt/hp2-awg-stack/stack.env`

## Routing Layer

После того как `AWG` уже поднят и работает на хосте, можно поставить маршрутизацию:

```bash
cd router
sudo bash install_awg_routing.sh
```

Installer:

- ставит `sing-box` и `nftables`, если это включено;
- генерирует host-level `sing-box` config;
- создаёт systemd unit `hp2-routing.service`;
- поднимает `sing-box` `tun`-inbound с `auto_route`, `auto_redirect` и `include_interface = AWG_IFACE`;
- использует штатные `ip rule`/`nftables` правила `sing-box`, а не самописный `TPROXY`;
- по умолчанию форсирует `ipv4_only` для DNS внутри `sing-box`;
- отбрасывает `UDP/443`, `853` и `STUN`, чтобы браузеры и приложения не зависали на `QUIC/DoQ` в transparent-режиме;
- по умолчанию отправляет только YouTube-связанные домены через `Hysteria2`;
- всё остальное оставляет напрямую.
- при каждой переустановке routing-layer может подтягивать актуальные wildcard-домены YouTube из [iplist.opencck.org](https://iplist.opencck.org/ru/).
- fetch из `iplist` теперь идёт с таймаутами и retry; по умолчанию при ошибке installer продолжает работу на встроенном списке доменов.
- installer больше не собирает `config.json` сам: он ставит отдельные `render_awg_routing_config.sh` и `update_blocked_domains.sh`, а затем вызывает render-скрипт.

Для routing-layer нужен `HY2_URI` в `.env` или в аргументе:

```bash
sudo HY2_URI='hy2://password@example.com:443/?sni=example.com&obfs=salamander&obfs-password=secret' bash install_awg_routing.sh
```

Статус:

```bash
sudo bash status_awg_routing.sh
journalctl -u hp2-routing.service -f
```

Для изолированной проверки второго хопа:

```bash
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org --max-time 15
```

## Замечания

- Текущий routing-layer рассчитан на клиентские профили с `AllowedIPs = 0.0.0.0/0`.
- Для этой схемы лучше использовать `DNS = 10.66.66.1` в клиентском профиле, чтобы DNS тоже уходил в transparent path.
- По умолчанию routing-layer поднимает локальный `dnsmasq`-фильтр и режет `HTTPS,SVCB` DNS records, чтобы клиенты меньше залипали на `QUIC`.
- По умолчанию installer добавляет локальное `INPUT ACCEPT` правило для `awg0`, потому что `sing-box auto_redirect` превращает клиентский TCP в локальные соединения к служебному порту, и `UFW` иначе их дропает.
- Debug SOCKS по умолчанию слушает `127.0.0.1:1080` и полезен для изолированной проверки `hy2-out`.
- По умолчанию exact YouTube-домены заданы вручную в `VPN_DOMAINS`, а из `iplist` тянутся только wildcard-домены.
- Чтобы поменять policy, используйте `ROUTE_FINAL`, `VPN_DOMAINS`, `VPN_SUFFIXES`, `IPLIST_DOMAINS_URL`, `IPLIST_WILDCARD_DOMAINS_URL`, `DIRECT_SUFFIXES`, `EXTRA_DIRECT_DOMAINS`, `EXTRA_DIRECT_SUFFIXES` в `.env`.
- Для ручного server-side fallback есть два списка:
  - `config/domains/blocked_domains.txt` для exact domains
  - `config/domains/blocked_suffixes.txt` для suffixes
- Для service-based fallback есть:
  - `config/domains/blocked_services.txt` - список сервисов, которые нужно целиком скачать из `iplist`
  - `config/domains/iplist_groups.tsv` - mapping `service -> group`
  - `/opt/hp2-routing/blocked_domains.generated.txt` - generated exact-list
  - `/opt/hp2-routing/blocked_suffixes.generated.txt` - generated suffix-list
  - `/opt/hp2-routing/blocked_services.state.tsv` - state-файл с `service -> group`
- `update_blocked_domains.sh` не меняет ручные файлы. Он читает `config/domains/blocked_services.txt`, скачивает домены из `iplist`, обновляет generated lists и, если что-то изменилось, заново запускает `render_awg_routing_config.sh` и перезапускает routing service.
- Чтобы отключить `iplist`, задайте `IPLIST_DOMAINS_URL=''` и `IPLIST_WILDCARD_DOMAINS_URL=''`.
- Чтобы падать при недоступности `iplist`, задайте `IPLIST_STRICT='1'`.
- Если клиентский веб-трафик уходит в `QUIC` и не открывает страницы, можно принудительно включить TCP fallback:

```bash
REJECT_UDP_443='1'
```

Это режет клиентский `UDP/443` на routing-layer и заставляет браузеры/приложения откатываться на `TCP/443`.
- Если этого недостаточно, оставьте включённым локальный DNS-фильтр:

```bash
DNS_FILTER_ENABLED='1'
DNS_FILTER_RR_TYPES='HTTPS,SVCB'
```

Тогда `sing-box` будет резолвить домены через локальный `dnsmasq`, который не отдаёт клиентам `HTTPS/SVCB` ответы и уменьшает вероятность повторного выбора `QUIC`.
- Для ручного обновления generated blocklist:

```bash
sudo bash update_blocked_domains.sh
```

- Чтобы добавить сервис целиком через `iplist`, запишите его имя в `config/domains/blocked_services.txt`. Например:

```text
youtube
instagram
openai
```

После этого updater сам скачает для каждого сервиса:
- exact domains в `blocked_domains.generated.txt`
- wildcard/suffix domains в `blocked_suffixes.generated.txt`

- Для ручного рендера конфига без полной переустановки:

```bash
sudo bash render_awg_routing_config.sh
sudo systemctl restart hp2-routing.service
```
- Для полного туннеля через `Hysteria2` без доменных условий задайте:

```bash
ROUTE_FINAL='hy2-out'
VPN_DOMAINS=''
VPN_SUFFIXES=''
IPLIST_DOMAINS_URL=''
IPLIST_WILDCARD_DOMAINS_URL=''
DIRECT_SUFFIXES=''
EXTRA_DIRECT_DOMAINS=''
EXTRA_DIRECT_SUFFIXES=''
```
