# AmneziaWG + Web Panel Installer

This directory contains a standalone bootstrap package only for:

- `AmneziaWG` on the host
- the web panel via `amneziawg-web.sh install`

It does not include the routing layer, `sing-box`, or `Hysteria2`.

## Files

- `install_amnezia_stack.sh` - main installer
- `status_amnezia_stack.sh` - quick `AWG` and panel status
- `.env.example` - variables template

## What the installer does

`install_amnezia_stack.sh`:

1. installs bootstrap dependencies (`git`, `curl`, `ca-certificates`) if enabled;
2. installs panel build dependencies (`build-essential`, `pkg-config`, `libssl-dev`) and `Rust/cargo` if the panel is enabled;
3. clones or updates `wiresock/amneziawg-install`;
4. runs `amneziawg-install.sh`;
5. brings up the web panel via `amneziawg-web.sh install`;
6. writes the installation log to `/opt/hp2-amnezia-stack/logs/install.log`;
7. saves the state file to `/opt/hp2-amnezia-stack/stack.env`.

## Quick Start

```bash
cd amnezia
cp .env.example .env
$EDITOR .env
sudo bash install_amnezia_stack.sh
```

With a separate env file:

```bash
sudo bash install_amnezia_stack.sh --env-file /root/hp2-amnezia-stack.env
```

## Main Variables

- `STACK_WORK_DIR` - working directory for checkout/logs/state
- `WIRESOCK_REF` - repository branch or tag
- `INSTALL_DEPENDENCIES=1` - install bootstrap dependencies via `apt`
- `INSTALL_WEB_PANEL=1` - install the panel
- `INSTALL_WEB_RUST=1` - automatically install `rustup/cargo` for the panel
- `AUTO_INSTALL=y` - run `amneziawg-install.sh` in non-interactive mode
- `SERVER_PUB_IP` - public server IP
- `SERVER_PUB_NIC` - external server interface
- `SERVER_AWG_NIC` - AWG interface name, usually `awg0`
- `SERVER_AWG_IPV4` - VPN IPv4 network
- `SERVER_AWG_IPV6` - VPN IPv6 network
- `SERVER_PORT` - server UDP port
- `CLIENT_DNS_1`, `CLIENT_DNS_2` - DNS servers for clients
- `ALLOWED_IPS` - allowed IPs in client configs
- `AWG_WEB_LISTEN` - panel listen address, default is `127.0.0.1:8080`
- `AWG_WEB_PUBLIC_BASE_URL` - external panel URL, if needed

## Verification

```bash
sudo bash status_amnezia_stack.sh
```

Additionally:

```bash
journalctl -u awg-quick@awg0.service -f
cd /opt/hp2-amnezia-stack/amneziawg-install && bash ./amneziawg-web.sh status
ss -ltnp | grep 8080 || true
```

## Logs

- install log: `/opt/hp2-amnezia-stack/logs/install.log`
- state file: `/opt/hp2-amnezia-stack/stack.env`
