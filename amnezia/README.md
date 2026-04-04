# AmneziaWG + Web Panel Installer

Этот каталог содержит отдельный bootstrap-пакет только для:

- `AmneziaWG` на хосте
- web panel через `amneziawg-web.sh install`

Он не включает routing-layer, `sing-box` или `Hysteria2`.

## Файлы

- `install_amnezia_stack.sh` - основной installer
- `status_amnezia_stack.sh` - быстрый статус `AWG` и панели
- `.env.example` - шаблон переменных

## Что делает installer

`install_amnezia_stack.sh`:

1. ставит bootstrap-зависимости (`git`, `curl`, `ca-certificates`), если это включено;
2. ставит зависимости для сборки панели (`build-essential`, `pkg-config`, `libssl-dev`) и `Rust/cargo`, если панель включена;
3. клонирует или обновляет `wiresock/amneziawg-install`;
4. запускает `amneziawg-install.sh`;
5. поднимает web panel через `amneziawg-web.sh install`;
6. пишет лог установки в `/opt/hp2-amnezia-stack/logs/install.log`;
7. сохраняет state-файл в `/opt/hp2-amnezia-stack/stack.env`.

## Быстрый старт

```bash
cd amnezia
cp .env.example .env
$EDITOR .env
sudo bash install_amnezia_stack.sh
```

С отдельным env-файлом:

```bash
sudo bash install_amnezia_stack.sh --env-file /root/hp2-amnezia-stack.env
```

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
sudo bash status_amnezia_stack.sh
```

Дополнительно:

```bash
journalctl -u awg-quick@awg0.service -f
cd /opt/hp2-amnezia-stack/amneziawg-install && bash ./amneziawg-web.sh status
ss -ltnp | grep 8080 || true
```

## Логи

- install log: `/opt/hp2-amnezia-stack/logs/install.log`
- state file: `/opt/hp2-amnezia-stack/stack.env`
