#!/usr/bin/env bash
# Применяет починку к серверу без сети. Всё идёт по stdin одной команды на цели,
# поэтому файлы и токен не попадают ни в аргументы процессов, ни в историю оболочки.
# По умолчанию сухой прогон. Перед каждой правкой копия файла, откат пишется в журнал на цели.
#
#   ./apply-on-server.sh --target "ssh -p 22022 -i КЛЮЧ admin@ХОСТ" [--token-file ФАЙЛ] [--apply]
#   ./apply-on-server.sh --profile stand --target "docker exec -i artel-stand" --token-file ФАЙЛ --apply
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=dry PROFILE=real TARGET= TOKEN_FILE=
while [ $# -gt 0 ]; do
  case $1 in
    --apply) MODE=apply ;;
    --profile) PROFILE=$2; shift ;;
    --target) TARGET=$2; shift ;;
    --token-file) TOKEN_FILE=$2; shift ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$TARGET" ] || { sed -n '6,7p' "$0" >&2; exit 2; }

case $PROFILE in
  real)
    BOT_DIR=/opt/bots/amigo BOT_MODULE=amigo.main MAIN_PY=/opt/bots/amigo/amigo/main.py
    OLD_BACKUP=/usr/local/sbin/amigo-backup.sh BACKUP_DIR=/var/backups/amigo BACKUP_NAME=amigo-src ;;
  stand)
    BOT_DIR=/opt/bots/demo BOT_MODULE=demo_bot MAIN_PY=/opt/bots/demo/demo_bot.py
    OLD_BACKUP=/usr/local/sbin/demo-backup.sh BACKUP_DIR=/var/backups/demo BACKUP_NAME=demo-src ;;
  *) echo "профиль: real или stand" >&2; exit 2 ;;
esac

remote() {
  cat <<'REMOTE'
set -eu
FIX=/opt/botfix ENV_FILE=$BOT_DIR/.env LOG_DIR=/var/log/botfix STATE_DIR=/run/botfix
PASS_FILE=/etc/botfix/backup.pass PORT=18190
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
JOURNAL=$LOG_DIR/apply-$STAMP.log ROLLBACK=$LOG_DIR/rollback-$STAMP.sh

say() { echo "$*"; [ "$MODE" = dry ] || echo "$(date -u +%H:%M:%S) $*" >>"$JOURNAL"; }
run() { say "+ $*"; [ "$MODE" = dry ] || "$@"; }
undo() { [ "$MODE" = dry ] || echo "$*" >>"$ROLLBACK"; }
save() {  # копия до правки, закрытая от чтения: в файлах бывают токены и пароли
  if [ -e "$1" ]; then
    local mode; mode=$(stat -c %a "$1")
    run cp -a "$1" "$1.bak-$STAMP"
    run chmod 600 "$1.bak-$STAMP"
    undo "cp -a '$1.bak-$STAMP' '$1' && chmod $mode '$1'"
  else
    undo "rm -f '$1'"
  fi
}
set_env() {  # printf встроенный: значение не появляется в аргументах процессов
  local tmp; tmp=$(mktemp "$ENV_FILE.XXXXXX")
  grep -v "^$1=" "$ENV_FILE" >"$tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
pids_of() {  # точное совпадение слова в argv: приманка с подписью через exec -a не подходит
  python3 - "$@" <<'PY'
import os, sys
want = set(sys.argv[1:])
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open(f"/proc/{pid}/cmdline", "rb").read().decode(errors="replace").split("\0")
    except OSError:
        continue
    words = {os.path.basename(a) for a in argv[1:]} | set(argv[1:])
    if int(pid) != os.getpid() and argv[0].rsplit("/", 1)[-1].startswith("python") and want & words:
        print(pid)
PY
}

echo "== проверка цели, режим $MODE =="
echo "PID 1: $(readlink /proc/1/exe)"
echo "маршрутов: $(($(wc -l </proc/net/route) - 1)), интерфейсы: $(ls /sys/class/net | tr '\n' ' ')"
python3 -c 'import sys, telegram; print("python", sys.version.split()[0], "ptb", telegram.__version__)'
for f in "$ENV_FILE" "$OLD_BACKUP" /entrypoint.sh; do
  [ -e "$f" ] && echo "есть $f" || { echo "НЕТ $f"; exit 1; }
done
[ "$MODE" = dry ] || { mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR"; touch "$ROLLBACK"; }

undo "kill \"\$(cat $STATE_DIR/supervisor.pid)\""
say "== 1. файлы починки в $FIX =="
if [ -e "$FIX" ]; then run mv "$FIX" "$FIX.bak-$STAMP"; undo "rm -rf '$FIX' && mv '$FIX.bak-$STAMP' '$FIX'"
else undo "rm -rf '$FIX'"; fi
run mkdir -p "$FIX" /etc/botfix "$STATE_DIR"
[ "$MODE" = dry ] || { printf '%s\n' "$PAYLOAD" | base64 -d | tar -xz --no-same-owner -C "$FIX"; chmod 755 "$FIX"/*; }
say "настройки в $FIX/botfix.env, реле на 127.0.0.1:$PORT, бот $BOT_MODULE, uid $BOT_UID"
[ "$MODE" = dry ] || cat >"$FIX/botfix.env" <<CONF
BOT_DIR=$BOT_DIR
BOT_ENV=$ENV_FILE
BOT_MODULE=$BOT_MODULE
BOT_UID=$BOT_UID
RELAY_LISTEN=127.0.0.1:$PORT
PROXY=http://127.0.0.1:$PORT
LOG_DIR=$LOG_DIR
STATE_DIR=$STATE_DIR
POLL_FILE=$STATE_DIR/last_poll
PASS_FILE=$PASS_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_NAME=$BACKUP_NAME
CONF

say "== 2. $ENV_FILE: только ключи, значения не печатаю =="
save "$ENV_FILE"
say "+ HTTPS_PROXY=http://127.0.0.1:$PORT"
[ "$MODE" = dry ] || set_env HTTPS_PROXY "http://127.0.0.1:$PORT"
if [ -n "$NEW_TOKEN" ]; then say "+ BOT_TOKEN заменён"; set_env BOT_TOKEN "$NEW_TOKEN"
elif [ "$TOKEN_GIVEN" = 1 ]; then say "+ BOT_TOKEN будет заменён, в сухом прогоне токен не передаю"
else say "BOT_TOKEN не меняю"; fi

say "== 3. очередь сообщений не сбрасывается при старте =="
if grep -q 'drop_pending_updates=True' "$MAIN_PY"; then
  save "$MAIN_PY"
  run sed -i 's/drop_pending_updates=True/drop_pending_updates=False/' "$MAIN_PY"
else say "в $MAIN_PY уже нет drop_pending_updates=True"; fi

say "== 4. пароль бэкапа в файл 600 =="
if [ ! -e "$PASS_FILE" ]; then
  save "$OLD_BACKUP"
  if [ "$MODE" = apply ]; then
    ( umask 077
      sed -n 's/^PASS=//p' "$OLD_BACKUP" | tr -d "\"'" >"$PASS_FILE.old"  # для старых архивов
      head -c 32 /dev/urandom | base64 >"$PASS_FILE" )
    printf '#!/bin/bash\nexec %s/backup.sh\n' "$FIX" >"$OLD_BACKUP"
    undo "rm -f '$PASS_FILE' '$PASS_FILE.old'"
  fi
  say "новый пароль в $PASS_FILE, старый в $PASS_FILE.old, $OLD_BACKUP вызывает $FIX/backup.sh"
else say "$PASS_FILE уже есть"; fi

say "== 5. супервизор из entrypoint =="
if ! grep -q botfix/supervisor.py /entrypoint.sh; then
  save /entrypoint.sh
  run sed -i -e '/^# bot-start/,/^# bot-end/d' \
    -e "s|^exec .*sleep infinity\$|exec python3 $FIX/supervisor.py|" /entrypoint.sh
else say "entrypoint уже запускает супервизор"; fi

say "== 6. запуск =="
OLD=$(pids_of "$BOT_MODULE" run_prod.py demo_bot.py | tr '\n' ' ')
say "старые процессы бота: ${OLD:-нет}"
[ -z "$OLD" ] || run kill $OLD
if [ -n "$(pids_of supervisor.py)" ]; then
  say "супервизор уже работает, перезапускаю бота"
  [ "$MODE" = dry ] || kill $(pids_of heartbeat.py) 2>/dev/null || true
else
  say "+ setsid python3 $FIX/supervisor.py"
  if [ "$MODE" = apply ]; then setsid python3 "$FIX/supervisor.py" </dev/null >>"$LOG_DIR/supervisor.out" 2>&1 & fi
fi
if [ "$MODE" = dry ]; then echo "== сухой прогон, ничего не изменено. Настоящий запуск: --apply =="; exit 0; fi
sleep 3
say "откат: bash $ROLLBACK, журнал: $JOURNAL"
python3 "$FIX/healthcheck.py" || true
REMOTE
}

{
  printf 'MODE=%q BOT_DIR=%q BOT_MODULE=%q BOT_UID=10001 MAIN_PY=%q OLD_BACKUP=%q BACKUP_DIR=%q BACKUP_NAME=%q\n' \
    "$MODE" "$BOT_DIR" "$BOT_MODULE" "$MAIN_PY" "$OLD_BACKUP" "$BACKUP_DIR" "$BACKUP_NAME"
  echo "TOKEN_GIVEN=$([ -n "$TOKEN_FILE" ] && echo 1 || echo 0)"
  if [ -n "$TOKEN_FILE" ] && [ "$MODE" = apply ]; then printf 'NEW_TOKEN=%q\n' "$(cat "$TOKEN_FILE")"
  else echo 'NEW_TOKEN='; fi
  echo 'PAYLOAD=$(cat <<"__PAYLOAD__"'
  COPYFILE_DISABLE=1 tar -C "$HERE/fix" -czf - relay.py supervisor.py healthcheck.py heartbeat.py backup.sh | base64
  echo '__PAYLOAD__'
  echo ')'
  remote
} | $TARGET bash -s

cat <<HINT

Внешний конец реле запускается на машине с сетью:
  python3 fix/relay.py out --allow api.telegram.org:443 --journal relay-out.log -- $TARGET python3 /opt/botfix/relay.py attach
HINT
[ "$PROFILE" = stand ] || echo "Настоящему боту для ответов ещё нужен второй --allow api.deepseek.com:443."
