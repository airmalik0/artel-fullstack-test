#!/usr/bin/env bash
# Один шаг развёртывания: ./scripts/step.sh <шаг> <host>
# Печатает одну строку JSON, код возврата 0 только при ok: true.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

step="${1:-}"
case "$step" in
  recon|harden|xray|hysteria|clientcfg|verify) ;;
  *) echo "шаги: recon harden xray hysteria clientcfg verify" >&2; exit 2 ;;
esac
load_target "${2:-}"
LOG="$OUT/logs/$step.log"
: >"$LOG"

COMMON_ENV=(
  "DEPLOY_USER=$DEPLOY_USER" "REALITY_SNI=$REALITY_SNI"
  "XRAY_VERSION=$XRAY_VERSION" "XRAY_SHA256_AMD64=$XRAY_SHA256_AMD64" "XRAY_SHA256_ARM64=$XRAY_SHA256_ARM64"
  "HYSTERIA_VERSION=$HYSTERIA_VERSION" "HYSTERIA_SHA256_AMD64=$HYSTERIA_SHA256_AMD64" "HYSTERIA_SHA256_ARM64=$HYSTERIA_SHA256_ARM64"
)

# Запись шага и выход с его кодом.
emit() {
  local json="$1"
  printf '%s\n' "$json" >"$OUT/steps/$step.json"
  python3 "$ROOT/scripts/lib/journal.py" "$OUT/journal.jsonl" <<<"$json"
  printf '%s\n' "$json"
  [ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' <<<"$json")" = True ]
  exit $?
}

failure() {
  emit "$(python3 -c 'import json,sys; print(json.dumps({"step":sys.argv[1],"ok":False,"changed":[],"checks":{},"facts":{},"reason":sys.argv[2]},ensure_ascii=False))' "$step" "$1")"
}

# Запускает сценарий и кладёт результат в RESULT, секрет в SECRET. Журнал только в файл.
collect() {
  local name="$1" tmp
  shift
  tmp="$(mktemp "$OUT/.run.XXXXXX")"
  run_remote "$name" "${COMMON_ENV[@]}" "$@" >"$tmp" 2>>"$LOG" || true
  RESULT="$(sed -n 's/^::result:://p' "$tmp" | tail -1)"
  SECRET="$(sed -n 's/^::secret:://p' "$tmp" | tail -1)"
  grep -v '^::' "$tmp" >>"$LOG" || true
  rm -f "$tmp"
  [ -n "$RESULT" ] || failure "шаг $name оборвался на цели, журнал: output/$HOST/logs/$step.log"
}

pick_login || failure "нет входа на $HOST ни под $DEPLOY_USER, ни под $FIRST_USER"

case "$step" in
  recon)
    printf '{"ts":"%s","run_start":true}\n' "$(date -Is)" >>"$OUT/journal.jsonl"
    collect recon
    emit "$RESULT"
    ;;
  harden)
    printf '%s\n' "$HOST" >"$ROOT/output/.active-deploy"
    rm -f "$ROOT/output/.active-deploy.blocks"
    PUBKEY="$(ssh-keygen -y -f "$KEY")"
    collect harden PHASE=user "PUBKEY=$PUBKEY"
    FIRST="$RESULT"
    python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["ok"] else 1)' <<<"$FIRST" || emit "$FIRST"
    # Root закрываем только после того, как новый вход проверен извне.
    ssh "${SSH_OPTS[@]}" -o ControlPath=none "$DEPLOY_USER@$HOST" 'sudo -n true' \
      || failure "вход под $DEPLOY_USER не работает, root не закрыт"
    LOGIN="$DEPLOY_USER"; SUDO="sudo -n"
    collect harden PHASE=lock "PUBKEY=$PUBKEY"
    emit "$(python3 "$ROOT/scripts/lib/merge.py" "$FIRST" "$RESULT")"
    ;;
  xray|hysteria)
    printf '%s\n' "$HOST" >"$ROOT/output/.active-deploy"
    collect "$step"
    emit "$RESULT"
    ;;
  clientcfg)
    collect clientcfg
    if [ -n "$SECRET" ]; then
      printf '%s' "$SECRET" | base64 -d \
        | python3 "$ROOT/scripts/lib/render_client.py" "$OUT/client" "$HOST" "$REALITY_SNI"
    fi
    SECRET=""
    emit "$RESULT"
    ;;
  verify)
    collect verify
    emit "$RESULT"
    ;;
esac
