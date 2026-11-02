#!/bin/bash
# Свежий контейнер формы сервера: без сети, бот под run_prod.py ходит через живое старое реле 18182.
# Старое реле это та же программа под другим именем, его внешний конец работает на хосте под systemd.
# Нужен хост с systemd.   ./up-real.sh ФАЙЛ_С_ТОКЕНОМ [ИМЯ_КОНТЕЙНЕРА]
set -eu
TOKEN_FILE=$1
NAME=${2:-artel-real}
HERE=$(cd "$(dirname "$0")" && pwd)
REPRO=$(cd "$HERE/../.." && pwd)
OLD=/opt/amigo-demo/ssh_api_relay.py

docker build -q -t artel-real -f "$HERE/Dockerfile" "$REPRO" >/dev/null
systemctl stop "$NAME-old-relay" 2>/dev/null || true
systemctl reset-failed "$NAME-old-relay" 2>/dev/null || true
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker create --name "$NAME" --hostname vps-real --network none --restart no artel-real >/dev/null

TMP=$(mktemp -d)
trap 'rm -f "$TMP/.env"; rmdir "$TMP"' EXIT
( umask 077
  printf 'BOT_TOKEN=%s\nHTTPS_PROXY=http://127.0.0.1:18182\nOTHER_KEY=keep-me\n' "$(cat "$TOKEN_FILE")" >"$TMP/.env" )
docker cp -q "$TMP/.env" "$NAME:/opt/bots/amigo/.env"
docker start "$NAME" >/dev/null
docker exec "$NAME" sh -c 'chown root:10001 /opt/bots/amigo/.env; chmod 640 /opt/bots/amigo/.env
  mkdir -p /run/oldrelay; chown 10001:10001 /run/oldrelay; chmod 700 /run/oldrelay'

docker exec -d -u 10001 "$NAME" python3 -I -u "$OLD" in --listen 127.0.0.1:18182 --link /run/oldrelay/link.sock
docker exec -d -u 10001 "$NAME" python3 -I -u /opt/amigo-demo/run_demo_bot.py
systemd-run --quiet --unit "$NAME-old-relay" --property Restart=always --property RestartSec=2 \
  /usr/bin/python3 -I -u "$REPRO/fix/relay.py" out --allow api.telegram.org:443 --journal "/root/$NAME-old-relay.log" -- \
  docker exec -i "$NAME" python3 -I "$OLD" attach --link /run/oldrelay/link.sock
docker exec -d "$NAME" bash -c 'setsid /usr/local/bin/python3 -B /opt/bots/amigo/run_prod.py </dev/null >/dev/null 2>&1 &'
echo "$NAME запущен: --network none, PID 1 $(docker exec "$NAME" readlink /proc/1/exe), .env $(docker exec "$NAME" stat -c '%a %U:%g' /opt/bots/amigo/.env)"
