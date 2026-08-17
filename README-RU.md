# vps-psiphon

Psiphon как локальный TCP-only SOCKS-прокси для Xray/Remnawave на Debian и Ubuntu.

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ap1w1/psiphon/main/psiphon_install.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/ap1w1/psiphon/main/psiphon_install.sh) --region DE
```

Кастомные настройки можно передать сразу: `--socks-port 1180 --http-port 8180`,
`--device-region CC`, `--egress-region CC`, `--image IMAGE`, `--publish-http 0|1`. HTTP по умолчанию
не публикуется (`0`). Полный список показывает `--help`. При обновлении значения из
`/etc/default/vps-psiphon` сохраняются, если они не переопределены аргументами.

Нужны root, Docker, curl, iproute2 (`ss`), systemd и nftables. Установщик сам останавливает старую
версию, удаляет контейнер, проверяет занятость host-портов, устанавливает и проверяет firewall,
запускает контейнер и выполняет health check SOCKS.

## Сеть и безопасность

Psiphon запускается с Docker `--network host`, без bridge-сети и без публикации `-p`. Процесс может
отображаться в `ss` как `*:1080` и `*:8080`. Это ожидаемо: отдельная таблица nftables
`inet psiphon_guard` блокирует TCP-доступ к обоим настроенным портам со всех интерфейсов, кроме
loopback. Локальная точка — `127.0.0.1:1080`, а через публичный IP порты SOCKS и HTTP недоступны.

Firewall обязательно применяется и проверяется **до** запуска host-network контейнера. Сервис
Psiphon требует `vps-psiphon-firewall.service`; оба сервиса включены после перезагрузки. Guard
использует собственную таблицу и не изменяет таблицу Remnawave `ip remnanode`.

Так устраняются Docker bridge-адреса наподобие `172.17.0.2`, конфликтующие с Remnawave
`egressFilter`, когда тот блокирует RFC1918 (включая `172.16.0.0/12`). Для Remnanode с
`network_mode: host` не нужны исключения из egress-фильтра: Xray по-прежнему подключается к loopback.

## Xray

Порт берётся из вывода установщика (по умолчанию 1080):

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": { "address": "127.0.0.1", "port": 1080 }
}
```

SOCKS Psiphon поддерживает только TCP. Нельзя направлять UDP через `psiphon-out`.

## Управление и проверки

```bash
vps-psiphon status
vps-psiphon logs
vps-psiphon restart
vps-psiphon uninstall
```

`status` реально проверяет таблицу nftables и оба правила портов. При отсутствии guard выводится
заметное `MISSING — SOCKS MAY BE PUBLIC`. Uninstall отключает оба сервиса и удаляет firewall:

```bash
docker inspect vps-psiphon --format '{{.HostConfig.NetworkMode}}'
nft list table inet psiphon_guard
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```
