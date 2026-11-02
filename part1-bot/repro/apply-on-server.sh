#!/usr/bin/env bash
# Применяет починку к серверу без сети. Всё идёт по stdin одной команды на цели,
# поэтому файлы и токен не попадают ни в аргументы процессов, ни в историю оболочки.
# По умолчанию сухой прогон. Перед каждой правкой копия файла, откат пишется в журнал на цели.
# Прежний бот и его запуск не трогаются, пока getMe не ответит через новое реле. Без внешнего конца реле
# --apply ставит файлы и вход реле и останавливается с кодом 3: поднимите внешний конец и повторите --apply.
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
[ -n "$TARGET" ] || { sed -n '8,9p' "$0" >&2; exit 2; }

case $PROFILE in
  real)
    BOT_DIR=/opt/bots/amigo BOT_MODULE=amigo.main MAIN_PY=/opt/bots/amigo/amigo/main.py OLD_NAMES="amigo.main run_prod.py"
    OLD_BACKUP=/usr/local/sbin/amigo-backup.sh BACKUP_DIR=/var/backups/amigo BACKUP_NAME=amigo-src
    OLD_ENTRY=/opt/bots/amigo/run_prod.py  # сам читает .env и сбрасывает права, стартует от root
    OLD_START_LINE="cd /opt/bots/amigo && exec /usr/local/bin/python3 -B $OLD_ENTRY" ;;
  stand)
    BOT_DIR=/opt/bots/demo BOT_MODULE=demo_bot MAIN_PY=/opt/bots/demo/demo_bot.py OLD_NAMES=demo_bot.py
    OLD_BACKUP=/usr/local/sbin/demo-backup.sh BACKUP_DIR=/var/backups/demo BACKUP_NAME=demo-src
    OLD_ENTRY=/opt/bots/demo/demo_bot.py
    OLD_START_LINE="cd /opt/bots/demo && set -a && . ./.env && set +a && exec setpriv --reuid=10001 --regid=10001 --clear-groups python3 -u demo_bot.py" ;;
  *) echo "профиль: real или stand" >&2; exit 2 ;;
esac

remote() {
  cat <<'REMOTE'
set -eu
FIX=/opt/botfix ENV_FILE=$BOT_DIR/.env LOG_DIR=/var/log/botfix STATE_DIR=/run/botfix
PASS_FILE=/etc/botfix/backup.pass PORT=18190
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
JOURNAL=$LOG_DIR/apply-$STAMP.log ROLLBACK=$LOG_DIR/rollback-$STAMP.sh PENDING=$LOG_DIR/rollback.pending

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
  local tmp owner mode
  owner=$(stat -c %u:%g "$ENV_FILE") mode=$(stat -c %a "$ENV_FILE")
  tmp=$(mktemp "$ENV_FILE.XXXXXX")  # mktemp даёт 600, владельца и права ставлю до подмены: бот читает файл сам
  grep -v "^$1=" "$ENV_FILE" >"$tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  chown "$owner" "$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$ENV_FILE"
}
scan() {  # $1 bot или decoy, дальше имена. Подпись argv[0] не считается: на сервере её подделывает exec -a
  python3 - "$@" <<'PY'
import os, sys
mode, names = sys.argv[1], set(sys.argv[2:])

def binary(pid):  # без CAP_SYS_PTRACE exe чужого uid не читается, тогда comm: exec -a его тоже не меняет
    try:
        return os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except PermissionError:
        return open(f"/proc/{pid}/comm").read().strip()

def runs(args):  # что интерпретатор запускает на самом деле
    args = iter(args)
    for a in args:
        if a == "-m":
            return next(args, "")
        if a == "-c":
            return ""
        if a in ("-W", "-X"):
            next(args, None)
        elif not a.startswith("-"):
            return os.path.basename(a)
    return ""

for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open(f"/proc/{pid}/cmdline", "rb").read().decode(errors="replace").split("\0")[:-1]
        name = binary(pid)
    except OSError:
        continue  # завершился или зомби
    if int(pid) == os.getpid() or not argv:
        continue
    real = name.startswith("python") and runs(argv[1:]) in names
    if mode == "bot" and real or mode == "decoy" and not real and any(n in argv[0] for n in names):
        print(pid)
PY
}
pids_of() { scan bot "$@"; }
alive() {  # зомби мёртв, но kill -0 отвечает за него успехом: собирать их на сервере некому
  local s; s=$(sed 's/.*) //; s/ .*//' "/proc/$1/stat" 2>/dev/null) && [ "$s" != Z ]
}
stop_pids() {  # процесс мог завершиться сам, под set -e это не должно оборвать применение на полпути
  local pid left i
  for pid in "$@"; do say "+ kill $pid"; [ "$MODE" = dry ] || kill "$pid" 2>/dev/null || say "pid $pid уже завершился"; done
  [ "$MODE" = apply ] || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do  # два опроса одного токена дают 409, ждём настоящего выхода
    left=
    for pid in "$@"; do if alive "$pid"; then left="$left $pid"; fi; done
    [ -n "$left" ] || return 0
    sleep 1
  done
  say "не завершились за 10 с:$left, kill -9"
  kill -9 $left 2>/dev/null || true
  sleep 1
}
stop_with() {  # остановка до правок: прежний бот работает как работал
  say "СТОП: $1"
  say "Прежний бот не тронут: $ENV_FILE, $MAIN_PY, /entrypoint.sh и процессы без изменений."
  say "Поставлены только $FIX и вход реле на 127.0.0.1:$PORT. Убрать их: bash $ROLLBACK"
  exit 3
}
probe() {  # getMe тем токеном, с которым бот будет работать. Токен только в окружении этой команды
  CHECK_TOKEN=$NEW_TOKEN CHECK_PROXY=http://127.0.0.1:$PORT CHECK_ENV=$ENV_FILE python3 -B - <<'PY'
import os, sys
sys.path.insert(0, "/opt/botfix")
from healthcheck import get_me, read_env
token = os.environ["CHECK_TOKEN"] or read_env(os.environ["CHECK_ENV"]).get("BOT_TOKEN", "")
ok, detail = get_me(token, os.environ["CHECK_PROXY"]) if token else (False, "в .env нет BOT_TOKEN")
print(detail)
sys.exit(0 if ok else 1)
PY
}
relay_up() {  # вход реле без бота: внешнему концу есть к чему подключиться, пока прежний бот работает
  local pid
  if [ -n "$(pids_of supervisor.py)" ]; then say "вход реле под супервизором"; return 0; fi
  if [ -s "$STATE_DIR/relay-in.pid" ] && alive "$(cat "$STATE_DIR/relay-in.pid")"; then
    say "вход реле уже поднят"; return 0
  fi
  say "+ вход реле на 127.0.0.1:$PORT под uid $BOT_UID"
  [ "$MODE" = apply ] || return 0
  install -d -o "$BOT_UID" -g "$BOT_UID" -m 700 "$STATE_DIR/bot"
  setsid setpriv --reuid="$BOT_UID" --regid="$BOT_UID" --clear-groups python3 -u "$FIX/relay.py" in \
    --listen "127.0.0.1:$PORT" --link "$STATE_DIR/bot/link.sock" </dev/null >>"$LOG_DIR/relay-in.log" 2>&1 &
  pid=$!
  echo "$pid" >"$STATE_DIR/relay-in.pid"
  sleep 1
  alive "$pid" || stop_with "вход реле не запустился, журнал $LOG_DIR/relay-in.log"
}
channel_alive() {
  local i detail
  for i in 1 2 3 4 5 6; do
    if detail=$(probe); then say "новый канал жив: getMe через 127.0.0.1:$PORT вернул $detail"; return 0; fi
    case $detail in *401*) break ;; esac
    sleep 3
  done
  stop_with "новый канал не отвечает: $detail"
}
trap 'rc=$?; [ "$MODE" = dry ] || [ "$rc" = 0 ] || [ "$rc" = 3 ] || [ "$rc" = 4 ] || echo "ОБОРВАНО, rc=$rc. Откат: bash $ROLLBACK"' EXIT

echo "== проверка цели, режим $MODE =="
[ "$(id -u)" = 0 ] || { echo "нужен root, сейчас uid $(id -u)"; exit 1; }
echo "PID 1: $(readlink /proc/1/exe)"
echo "маршрутов: $(($(wc -l </proc/net/route) - 1)), интерфейсы: $(ls /sys/class/net | tr '\n' ' ')"
python3 -c 'import sys, telegram; print("python", sys.version.split()[0], "ptb", telegram.__version__)'
for f in "$ENV_FILE" "$OLD_BACKUP" /entrypoint.sh; do
  [ -e "$f" ] && echo "есть $f" || { echo "НЕТ $f"; exit 1; }
done
command -v setpriv >/dev/null || { echo "НЕТ setpriv"; exit 1; }
grep -q -e '^exec .*sleep infinity$' -e botfix/supervisor.py /entrypoint.sh || { echo "НЕТ строки PID 1 в /entrypoint.sh"; exit 1; }
echo "$ENV_FILE: $(stat -c '%a %U:%g' "$ENV_FILE")"
OLD=$(pids_of $OLD_NAMES | tr '\n' ' ')
echo "прежние процессы бота: ${OLD:-нет}"
for pid in $(scan decoy "$BOT_MODULE"); do
  echo "приманка $pid: подпись '$(tr '\0' ' ' </proc/$pid/cmdline | cut -c1-60)', настоящий бот так не запускается"
done
RESUMED=0
if [ "$MODE" = apply ]; then
  mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR"
  if [ -s "$PENDING" ]; then ROLLBACK=$(cat "$PENDING") RESUMED=1  # прошлый запуск остановился до правок, откат общий
  else touch "$ROLLBACK"; echo "$ROLLBACK" >"$PENDING"; fi
fi

say "== 1. файлы починки в $FIX =="
if [ "$RESUMED" = 1 ]; then say "подготовка прошлого запуска на месте, файлы обновляю"
else
  undo "rm -f '$PENDING'"
  if [ -e "$FIX" ]; then run mv "$FIX" "$FIX.bak-$STAMP"; undo "rm -rf '$FIX' && mv '$FIX.bak-$STAMP' '$FIX'"
  else undo "rm -rf '$FIX'"; fi
  undo "[ ! -s '$STATE_DIR/relay-in.pid' ] || kill \"\$(cat '$STATE_DIR/relay-in.pid')\"; rm -f '$STATE_DIR/relay-in.pid'"
fi
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
POLL_FILE=$STATE_DIR/bot/last_poll
PASS_FILE=$PASS_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_NAME=$BACKUP_NAME
CONF

say "== 2. новый канал: дальше только если getMe ответит через новое реле =="
relay_up
if [ "$MODE" = apply ]; then channel_alive; else say "+ getMe через 127.0.0.1:$PORT, без ответа остановка кодом 3 до всех правок"; fi

say "== 3. $ENV_FILE: только ключи, значения не печатаю, владелец и права прежние =="
save "$ENV_FILE"
say "+ HTTPS_PROXY=http://127.0.0.1:$PORT"
[ "$MODE" = dry ] || set_env HTTPS_PROXY "http://127.0.0.1:$PORT"
if [ -n "$NEW_TOKEN" ]; then say "+ BOT_TOKEN заменён"; set_env BOT_TOKEN "$NEW_TOKEN"
elif [ "$TOKEN_GIVEN" = 1 ]; then say "+ BOT_TOKEN будет заменён, в сухом прогоне токен не передаю"
else say "BOT_TOKEN не меняю"; fi
[ "$MODE" = dry ] || setpriv --reuid="$BOT_UID" --regid="$BOT_UID" --clear-groups test -r "$ENV_FILE" ||
  { say "uid $BOT_UID не читает $ENV_FILE"; exit 1; }

say "== 4. очередь сообщений не сбрасывается при старте =="
if grep -q 'drop_pending_updates=True' "$MAIN_PY"; then
  save "$MAIN_PY"
  run sed -i 's/drop_pending_updates=True/drop_pending_updates=False/' "$MAIN_PY"
else say "в $MAIN_PY уже нет drop_pending_updates=True"; fi

say "== 5. пароль бэкапа в файл 600 =="
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

say "== 6. супервизор из entrypoint, запуск приманки убираю =="
if ! grep -q botfix/supervisor.py /entrypoint.sh; then
  save /entrypoint.sh
  # На сервере маркеров bot-start нет: бот оттуда не стартует, а приманка это строка с подписью бота.
  run sed -i -e '/^# bot-start/,/^# bot-end/d' -e "/^[A-Za-z_]* \"python3 -m $BOT_MODULE\"\$/d" \
    -e "s|^exec .*sleep infinity\$|exec python3 $FIX/supervisor.py|" /entrypoint.sh
else say "entrypoint уже запускает супервизор"; fi

say "== 7. переключение =="
OLD=$(pids_of $OLD_NAMES | tr '\n' ' ')
OLD_START=$LOG_DIR/old-start-$STAMP.txt
if [ -n "$OLD" ]; then
  say "строка запуска прежнего бота (задана профилем, из /proc не берётся: argv пишет сам процесс):"
  say "  $OLD_START_LINE"
  [ "$MODE" = dry ] || echo "$OLD_START_LINE" >>"$OLD_START"
fi
if [ "$MODE" = apply ]; then cat >>"$ROLLBACK" <<TAIL
# Файлы восстановлены выше. Дальше новое останавливается и возвращается прежний процесс.
alive() { s=\$(sed 's/.*) //; s/ .*//' "/proc/\$1/stat" 2>/dev/null) && [ "\$s" != Z ]; }
START=$OLD_START
LINE=$(printf %q "$OLD_START_LINE")
ENTRY=$OLD_ENTRY
trusted() {  # строка идёт от root: файл и все каталоги над ним только root
  BAD=\$ENTRY
  while :; do
    case "\$(stat -c '%u %a' "\$BAD" 2>/dev/null)" in
      "0 "[0-7][0145][0145]) ;;
      *) return 1 ;;
    esac
    [ "\$BAD" = / ] && return 0
    BAD=\$(dirname "\$BAD")
  done
}
TRUSTED=1; trusted || TRUSTED=0
if [ -s "\$START" ] && [ "\$TRUSTED" = 1 ]; then
  echo "Запуск прежнего бота от root:"
  printf "  setsid bash -c %q </dev/null >>$LOG_DIR/old-bot.out 2>&1 &\n" "\$LINE"
fi
[ "\$TRUSTED" = 1 ] || echo "\$BAD не принадлежит root или открыт на запись другим, строку запуска не выдаю."
SV=\$(cat $STATE_DIR/supervisor.pid 2>/dev/null || true)
if [ "\$SV" = 1 ]; then
  echo "Супервизор это PID 1: контейнер остановится. После его старта запустите прежнего бота строкой выше, если она напечатана."
  kill 1; exit 0
fi
if [ -n "\$SV" ]; then
  kill "\$SV" 2>/dev/null
  i=0; while [ \$i -lt 15 ] && alive "\$SV"; do sleep 1; i=\$((i + 1)); done  # супервизор ждёт своих детей
fi
[ -s "\$START" ] || { echo "Прежнего бота не было, запускать нечего."; exit 0; }
[ "\$TRUSTED" = 1 ] || { echo "Прежний бот не запущен."; exit 1; }
setsid bash -c "\$LINE" </dev/null >>$LOG_DIR/old-bot.out 2>&1 &
pid=\$!
sleep 3
if alive "\$pid"; then echo "Прежний бот запущен, pid \$pid."
else echo "ПРЕЖНИЙ БОТ НЕ ЗАПУСТИЛСЯ, журнал $LOG_DIR/old-bot.out, строка выше."; fi
TAIL
fi
say "прежние процессы бота: ${OLD:-нет}"
[ -z "$OLD" ] || stop_pids $OLD
DECOY=$(scan decoy "$BOT_MODULE" | tr '\n' ' ')
[ -z "$DECOY" ] || { say "приманка: $DECOY"; stop_pids $DECOY; }
if [ -n "$(pids_of supervisor.py)" ]; then
  say "супервизор уже работает, перезапускаю бота"
  stop_pids $(pids_of heartbeat.py)
else
  [ ! -s "$STATE_DIR/relay-in.pid" ] || stop_pids "$(cat "$STATE_DIR/relay-in.pid")"
  say "+ setsid python3 $FIX/supervisor.py"
  if [ "$MODE" = apply ]; then setsid python3 "$FIX/supervisor.py" </dev/null >>"$LOG_DIR/supervisor.out" 2>&1 & fi
fi
if [ "$MODE" = dry ]; then echo "== сухой прогон, ничего не изменено. Настоящий запуск: --apply =="; exit 0; fi
say "откат: bash $ROLLBACK, журнал: $JOURNAL"
say "== 8. проверка: бот сам опрашивает Telegram через новое реле =="
for i in $(seq 1 20); do
  sleep 3
  if line=$(python3 "$FIX/healthcheck.py"); then say "$line"; rm -f "$PENDING"; exit 0; fi
done
say "$line"
say "Бот не поднялся за минуту. Откат: bash $ROLLBACK"
exit 4
REMOTE
}

rc=0
{
  printf 'MODE=%q BOT_DIR=%q BOT_MODULE=%q BOT_UID=10001 MAIN_PY=%q OLD_BACKUP=%q BACKUP_DIR=%q BACKUP_NAME=%q OLD_NAMES=%q OLD_ENTRY=%q OLD_START_LINE=%q\n' \
    "$MODE" "$BOT_DIR" "$BOT_MODULE" "$MAIN_PY" "$OLD_BACKUP" "$BACKUP_DIR" "$BACKUP_NAME" "$OLD_NAMES" "$OLD_ENTRY" "$OLD_START_LINE"
  echo "TOKEN_GIVEN=$([ -n "$TOKEN_FILE" ] && echo 1 || echo 0)"
  if [ -n "$TOKEN_FILE" ] && [ "$MODE" = apply ]; then printf 'NEW_TOKEN=%q\n' "$(cat "$TOKEN_FILE")"
  else echo 'NEW_TOKEN='; fi
  echo 'PAYLOAD=$(cat <<"__PAYLOAD__"'
  COPYFILE_DISABLE=1 tar -C "$HERE/fix" -czf - relay.py supervisor.py healthcheck.py heartbeat.py backup.sh | base64
  echo '__PAYLOAD__'
  echo ')'
  remote
} | $TARGET bash -s || rc=$?

if [ "$rc" != 0 ] || [ "$MODE" = dry ]; then cat <<HINT

Внешний конец реле запускается на машине с сетью, потом повторите эту же команду с --apply:
  python3 fix/relay.py out --allow api.telegram.org:443 --journal relay-out.log -- $TARGET python3 /opt/botfix/relay.py attach
HINT
  [ "$PROFILE" = stand ] || echo "Настоящему боту для ответов ещё нужен второй --allow api.deepseek.com:443."
fi
exit "$rc"
