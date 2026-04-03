# Router Sidecar For AmneziaWG -> Hysteria2

Этот каталог содержит Docker-based router sidecar для российской точки входа с `AmneziaWG`.

Схема:
- клиент подключается к российскому серверу через `AmneziaWG`;
- `AmneziaWG` живет в docker-контейнере `amnezia-awg2`;
- sidecar-контейнер делит с ним network namespace, видит `awg0`, поднимает `TPROXY` и запускает `sing-box`;
- домены в зонах `.ru` и `.рф` отправляются напрямую;
- остальной трафик уходит на зарубежный `Hysteria 2`.

## Что входит

- `Dockerfile` - образ с `sing-box`, `nftables`, `iproute2`
- `entrypoint.sh` - настраивает `TPROXY` и запускает `sing-box`
- `install_router.sh` - читает параметры из `.env` или `--env-file`, генерирует конфиг и запускает sidecar
- `remove_router.sh` - удаляет sidecar
- `status_router.sh` - показывает состояние и логи
- `.env.example` - шаблон переменных без секретов

## Ограничения текущей версии

- прямой маршрут определяется по доменным suffix-правилам: `ru` и `xn--p1ai`;
- IP-only трафик без доменного имени по умолчанию уходит через `Hysteria 2`;
- если `Amnezia` пересоздаст контейнер `amnezia-awg2`, нужно просто снова запустить `install_router.sh`;
- это минимальный production-oriented пакет, а не полная geosite/geoip-маршрутизация.

## Требования

- Ubuntu/Debian сервер
- установленный Docker
- уже работающий контейнер `AmneziaWG` (`amnezia-awg2` по умолчанию)
- root-доступ
- рабочий `HY2_URI` для зарубежного `Hysteria 2`

## Быстрый старт

На российском сервере:

```bash
cd router
chmod +x install_router.sh remove_router.sh status_router.sh entrypoint.sh
cp .env.example .env
$EDITOR .env
sudo bash install_router.sh
```

Или можно передать отдельный env-файл:

```bash
sudo bash install_router.sh --env-file /root/hp2-router.env
```

После запуска скрипт:
- проверит контейнер `amnezia-awg2`;
- сгенерирует `sing-box` конфиг в `/opt/hp2-router/config/config.json`;
- соберет образ `hp2-router:latest`;
- запустит контейнер `hp2-router` в режиме `--network container:amnezia-awg2`.

`config.json` содержит секреты `Hysteria 2` и создается с правами `0600`.
Файл с исходными переменными по умолчанию не сохраняется. Если он нужен, включите `SAVE_STATE_ENV=1`.

## Дополнительные параметры

Можно переопределить:

```bash
sudo \
  AMNEZIA_CONTAINER='amnezia-awg2' \
  CONTAINER_NAME='hp2-router' \
  AWG_IFACE='awg0' \
  DIRECT_SUFFIXES='ru,xn--p1ai' \
  EXTRA_DIRECT_DOMAINS='gosuslugi.ru,ya.ru' \
  EXTRA_DIRECT_SUFFIXES='yandex.ru' \
  bash install_router.sh
```

Описание:
- `HY2_URI` - URI второго хопа `Hysteria 2`
- `INPUT_ENV_FILE` - путь к env-файлу, если не используете `--env-file`
- `AMNEZIA_CONTAINER` - имя контейнера `AmneziaWG`
- `CONTAINER_NAME` - имя sidecar-контейнера
- `AWG_IFACE` - интерфейс внутри контейнера `AmneziaWG`
- `DIRECT_SUFFIXES` - доменные suffixes, которые идут напрямую
- `EXTRA_DIRECT_DOMAINS` - точные домены, которые всегда идут напрямую
- `EXTRA_DIRECT_SUFFIXES` - дополнительные suffixes для прямого маршрута
- `SAVE_STATE_ENV=1` - сохранить эффективные параметры в `/opt/hp2-router/router.env`

## Формат `.env`

Минимальный пример:

```bash
HY2_URI='hy2://password@example.com:443/?sni=example.com&obfs=salamander&obfs-password=secret'
```

Полный пример смотрите в `.env.example`.

## Проверка

```bash
sudo bash status_router.sh
docker logs -f hp2-router
```

Если надо посмотреть конфиг:

```bash
sudo sed -n '1,240p' /opt/hp2-router/config/config.json
```

## Удаление

Удалить только контейнер:

```bash
sudo bash remove_router.sh
```

Удалить контейнер, образ и конфиг:

```bash
sudo REMOVE_IMAGE=1 PURGE_CONFIG=1 bash remove_router.sh
```

## Как это работает

`entrypoint.sh` внутри sidecar:
- ждет появления `awg0`;
- включает `ip_forward`, отключает `rp_filter`, включает `src_valid_mark`;
- создает `ip rule` и `local route` для `fwmark`;
- создает `nftables` `TPROXY` rule только для трафика, который приходит через `awg0`;
- запускает `sing-box`.

`sing-box`:
- перехватывает TCP/UDP через `tproxy`;
- sniff'ит протоколы;
- отправляет `.ru` и `.рф` напрямую;
- DNS-запросы hijack'ит в локальный DNS модуль;
- все остальное маршрутизирует в `Hysteria 2`.

## Что стоит улучшить позже

- заменить suffix-only роутинг на полноценные `rule_set` для российских сервисов;
- добавить `systemd`-обвязку на хосте для автоперезапуска после пересоздания `Amnezia` контейнера;
- добавить отдельный healthcheck и smoke-test маршрутизации.
