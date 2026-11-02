#!/bin/bash
# Чистый контейнер стенда в состоянии «до»: без сети, PID 1 это sleep, бот запущен один раз.
# Токен попадает в контейнер файлом .env, в аргументы команд не попадает.
#   ./up.sh ФАЙЛ_С_ТОКЕНОМ [ИМЯ_КОНТЕЙНЕРА]
set -eu
TOKEN_FILE=$1
NAME=${2:-artel-stand}
HERE=$(cd "$(dirname "$0")" && pwd)

docker build -q -t artel-stand "$HERE" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker create --name "$NAME" --hostname vps-stand --network none --restart no artel-stand >/dev/null

TMP=$(mktemp -d)
trap 'rm -f "$TMP/.env"; rmdir "$TMP"' EXIT
( umask 077; printf 'BOT_TOKEN=%s\n' "$(cat "$TOKEN_FILE")" > "$TMP/.env" )
docker cp -q "$TMP/.env" "$NAME:/opt/bots/demo/.env"
docker start "$NAME" >/dev/null
echo "$NAME запущен: --network none, PID 1 $(docker exec "$NAME" readlink /proc/1/exe)"
