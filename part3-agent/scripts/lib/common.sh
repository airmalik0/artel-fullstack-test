# shellcheck shell=bash
# Общее для локальных скриптов: настройки, ssh, запуск шага на цели.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"

# Эти скрипты выполняются вне песочницы, а в корень папки bash агента писать может.
# Поэтому ничего не берём из cwd и окружения: фиксированный PATH, каталог без записи,
# python только с -I, чтобы рядом не подложили модуль.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE BASH_ENV ENV CDPATH
unset LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
export PYTHONSAFEPATH=1
cd "$ROOT/scripts"

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/versions.env"

# Одно значение из окружения или .env. Файл не исполняется целиком: в окружение
# скрипта не попадёт ничего лишнего, в том числе токен.
env_get() {
  local key="$1" default="${2:-}" value
  value="$(printenv "$key" || true)"
  if [ -z "$value" ] && [ -f "$ROOT/.env" ]; then
    value="$(sed -n "s/^${key}=//p" "$ROOT/.env" | tail -1)"
  fi
  printf '%s' "${value:-$default}"
}

valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
    echo "недопустимый host: $1" >&2
    exit 2
  }
}

load_target() {
  HOST="$1"
  valid_host "$HOST"
  DEPLOY_USER="$(env_get DEPLOY_USER vpnops)"
  FIRST_USER="$(env_get TARGET_SSH_USER root)"
  REALITY_SNI="$(env_get REALITY_SNI www.microsoft.com)"
  [[ "$DEPLOY_USER$FIRST_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "недопустимый пользователь" >&2; exit 2; }
  valid_host "$REALITY_SNI"
  REALITY_EXTRA_NAMES="$(env_get REALITY_EXTRA_NAMES c.s-microsoft.com,wwwqa.microsoft.com)"
  REALITY_ALT_PORT="$(env_get REALITY_ALT_PORT 8443)"
  [ -n "$REALITY_EXTRA_NAMES" ] || { echo "нужно хотя бы одно имя в REALITY_EXTRA_NAMES" >&2; exit 2; }
  local name
  for name in ${REALITY_EXTRA_NAMES//,/ }; do valid_host "$name"; done
  [[ "$REALITY_ALT_PORT" =~ ^[1-9][0-9]{2,4}$ ]] && [ "$REALITY_ALT_PORT" -le 65535 ] \
    || { echo "недопустимый REALITY_ALT_PORT" >&2; exit 2; }
  case "$REALITY_ALT_PORT" in
    22|80|443|3306|8080) echo "REALITY_ALT_PORT не может быть $REALITY_ALT_PORT" >&2; exit 2 ;;
  esac
  KEY="$(env_get TARGET_SSH_KEY secrets/target_ed25519)"
  case "$KEY" in /*) ;; *) KEY="$ROOT/$KEY" ;; esac
  [ -f "$KEY" ] || { echo "нет ключа для входа на цель: tools/new-target-key.sh" >&2; exit 2; }
  OUT="$ROOT/output/$HOST"
  mkdir -p "$OUT/steps" "$OUT/logs"
  chmod 700 "$ROOT/output" "$OUT"
  SSH_OPTS=(-F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
    -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$OUT/known_hosts")
}

# Определяет, под кем заходить: до укрепления root, после него DEPLOY_USER.
pick_login() {
  if ssh -n "${SSH_OPTS[@]}" "$DEPLOY_USER@$HOST" 'sudo -n true' 2>/dev/null; then
    LOGIN="$DEPLOY_USER"; SUDO="sudo -n"
  elif ssh -n "${SSH_OPTS[@]}" "$FIRST_USER@$HOST" 'true' 2>/dev/null; then
    LOGIN="$FIRST_USER"
    if [ "$FIRST_USER" = root ]; then SUDO=""; else SUDO="sudo -n"; fi
  else
    return 1
  fi
}

remote_sh() { ssh "${SSH_OPTS[@]}" "$LOGIN@$HOST" "$SUDO bash -s"; }

# Собирает сценарий шага и запускает на цели под root. stdout сценария: журнал
# и одна строка ::result::.
run_remote() {
  local step="$1"
  shift
  {
    printf 'STEP=%q\n' "$step"
    local kv
    for kv in "$@"; do printf 'export %q\n' "$kv"; done
    cat "$ROOT/scripts/remote/lib.sh" "$ROOT/scripts/remote/$step.sh"
  } | ssh "${SSH_OPTS[@]}" "$LOGIN@$HOST" \
    "umask 077; f=\$(mktemp); cat > \$f; $SUDO bash \$f; rc=\$?; rm -f \$f; exit \$rc"
}
