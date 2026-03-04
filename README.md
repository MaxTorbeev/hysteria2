# Скрипт установки git для Debian

В репозитории находится `install_hy2_debian.sh` - скрипт для быстрой установки сервера Hysteria2 на Debian.

Что делает скрипт:
- устанавливает зависимости (`curl`, `openssl`, `certbot`, `qrencode`);
- скачивает последнюю версию бинарника Hysteria2;
- выпускает сертификат Let's Encrypt для вашего домена;
- генерирует конфиг сервера с `password`-авторизацией, `obfs` Salamander и локальной маскировкой;
- создает и запускает `systemd`-сервис (`hysteria-server`);
- выводит клиентские ссылки (`hy2://` и `hysteria2://`) и QR-код в терминале.

## Требования

- Сервер на Debian 11/12+
- Права `root` (или запуск через `sudo`)
- Публичный домен, указывающий на IP сервера (A/AAAA запись)
- Открытые порты:
  - `80/tcp` для HTTP-челленджа Let's Encrypt
  - `443/udp` (или ваш кастомный UDP-порт) для Hysteria2
- Доступ сервера в интернет к:
  - GitHub Releases
  - Let's Encrypt
  - Debian mirrors

## Какие файлы создаются

- `/usr/local/bin/hysteria`
- `/etc/hysteria/config.yaml`
- `/etc/hysteria/auth.txt`
- `/etc/hysteria/obfs.txt`
- `/etc/hysteria/masquerade/index.html`
- `/etc/systemd/system/hysteria-server.service`
- `/etc/letsencrypt/renewal-hooks/deploy/hysteria-restart.sh`
- `/root/hy2-<domain>.png` (PNG с QR-кодом)

## Быстрый старт

```bash
cd /Users/mxt/Code/hp2
chmod +x install_hy2_debian.sh
sudo DOMAIN=hp2.maxtor.name EMAIL=admin@maxtor.name PORT=443 bash install_hy2_debian.sh
```

Если `EMAIL` не указан, скрипт запросит его интерактивно.

## Переменные окружения

- `DOMAIN` (по умолчанию: `hp2.maxtor.name`)
- `EMAIL` (обязателен для Let's Encrypt, можно ввести при запуске)
- `PORT` (по умолчанию: `443`)

Пример:

```bash
sudo DOMAIN=example.com EMAIL=ops@example.com PORT=8443 bash install_hy2_debian.sh
```

## Добавление нового пользователя

Для добавления клиента используйте `add_hy2_user.sh`:

```bash
cd /Users/mxt/Code/hp2
chmod +x add_hy2_user.sh
sudo bash add_hy2_user.sh <username> [password]
```

Примеры:

```bash
sudo bash add_hy2_user.sh ivan
sudo bash add_hy2_user.sh ivan MyStrongPass123
```

Что делает скрипт:
- добавляет пользователя в `/etc/hysteria/users.db`;
- переводит `auth` в `userpass` в `/etc/hysteria/config.yaml`;
- если сервер был в режиме одного пароля (`auth: password`), сохраняет старый пароль как пользователя `main`;
- перезапускает `hysteria-server`;
- выводит `hy2://` и `hysteria2://` URI и QR-код для нового пользователя.

## Проверка сервиса

```bash
systemctl status hysteria-server --no-pager
journalctl -u hysteria-server -n 100 --no-pager
ss -lunp | rg ':443|:8443'
```

## Повторный запуск скрипта

- Существующий секрет auth сохраняется: `/etc/hysteria/auth.txt`
- Существующий секрет obfs сохраняется: `/etc/hysteria/obfs.txt`
- Конфиг и unit-файлы перезаписываются актуальными значениями
- Сервис повторно включается/перезапускается через `systemd`

## Импорт в клиент

В конце скрипт выводит:
- `hy2://...`
- `hysteria2://...`

Используйте любую из ссылок в совместимом клиенте (например, на базе sing-box).  
QR в терминале и PNG-файл содержат `hy2://` URI с параметрами obfs.

## Важное примечание про Obfs и маскировку

Скрипт включает `obfs: salamander` и одновременно раздает локальную страницу маскировки для домена.

- Obfs повышает устойчивость к простому DPI и сигнатурным блокировкам.
- При включенном obfs трафик не выглядит как обычный HTTP/3 endpoint.
- Настройки obfs (тип и пароль) должны совпадать на клиенте и сервере.

## Решение проблем

### `Could not get lock /var/lib/dpkg/lock-frontend`

Это значит, что сейчас уже идет другой процесс apt/dpkg (часто `unattended-upgrades`). Подождите и повторите:

```bash
ps -p 7503 -o pid,etime,cmd
systemctl status unattended-upgrades
```

### Не выпускается сертификат Let's Encrypt

Проверьте:
- домен указывает на IP вашего сервера;
- `80/tcp` доступен снаружи;
- другой сервис не занимает порт 80 во время `certbot --standalone`.

### Сервис не запускается

```bash
journalctl -u hysteria-server -n 200 --no-pager
cat /etc/hysteria/config.yaml
```

## Рекомендации по безопасности

- Периодически ротируйте `/etc/hysteria/auth.txt` и `/etc/hysteria/obfs.txt`.
- Ограничьте доступ по SSH и поддерживайте Debian в актуальном состоянии.
- Для продакшена добавьте ACL и rate-limit на уровне firewall.
