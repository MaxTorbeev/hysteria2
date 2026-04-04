# AmneziaWG Bootstrap With wiresock/amneziawg-install

Этот каталог теперь содержит новый bootstrap-пакет для **чистого сервера**.

Он больше не использует старую схему с `TPROXY`, `sing-box`, sidecar-контейнерами или миграцией из dockerized `Amnezia`.
Вместо этого installer опирается на [`wiresock/amneziawg-install`](https://github.com/wiresock/amneziawg-install) и поднимает:

- `AmneziaWG` на сервере;
- веб-панель через `amneziawg-web.sh install`.

## Что входит

- `install_awg_stack.sh` - основной installer для нового чистого сервера
- `status_awg_stack.sh` - быстрый статус для `AmneziaWG` и панели
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
- `ALLOWED_IPS` - allowed IPs в клиентских конфигах
- `AWG_WEB_LISTEN` - адрес панели, по умолчанию `127.0.0.1:8080`
- `AWG_WEB_PUBLIC_BASE_URL` - внешний URL панели, если он нужен

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

## Что удалено

Старый стек, связанный с:

- `TPROXY`
- `sing-box`
- host-level router scripts
- docker migration helper

удалён из этого каталога и больше не поддерживается этим bootstrap-пакетом.
