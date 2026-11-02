# shellcheck shell=bash
# Общее для локальных скриптов: настройки, ssh, запуск шага на цели.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
