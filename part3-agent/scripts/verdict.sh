#!/usr/bin/env bash
# Итог развёртывания: ./scripts/verdict.sh <host>
# Сервер проверяется шагом verify, снаружи проверяются порты, закрытые входы и
# реальный трафик через каждый транспорт. Результат: output/<host>/verdict.json.
# Код возврата 0 только если прошло всё.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_target "${1:-}"

T="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT
CHECKS="$T/checks"
: >"$CHECKS"
mark() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$CHECKS"; }

# Состояние на самой цели.
if "$ROOT/scripts/step.sh" verify "$HOST" >"$T/verify.json" 2>/dev/null; then mark server_state ok; else
  mark server_state fail "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])' <"$T/verify.json" 2>/dev/null || echo 'нет ответа')"
fi

# Снаружи: root и пароль закрыты, лишних портов нет.
if ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$OUT/known_hosts" "root@$HOST" true 2>/dev/null; then
  mark ext_root_closed fail "root входит по ключу"
else mark ext_root_closed ok; fi
pw="$(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=$OUT/known_hosts" "$DEPLOY_USER@$HOST" true 2>&1 || true)"
case "$pw" in
  *"Permission denied (publickey)"*) mark ext_password_closed ok ;;
  *) mark ext_password_closed fail "$(printf '%s' "$pw" | head -c 120)" ;;
esac
python3 - "$HOST" "$T/ports" <<'PY'
import socket, sys
host, path = sys.argv[1:3]
with open(path, "w") as fh:
    for port in (22, 443, 80, 8080, 3306):
        s = socket.socket(); s.settimeout(4)
        fh.write(f"{port} {'open' if s.connect_ex((host, port)) == 0 else 'closed'}\n")
        s.close()
PY
if grep -q '^22 open' "$T/ports" && grep -q '^443 open' "$T/ports" \
  && ! grep -qE '^(80|8080|3306) open' "$T/ports"; then mark ext_ports ok
else mark ext_ports fail "$(paste -sd' ' "$T/ports")"; fi

# Клиентские бинари закреплены той же контрольной суммой, что и на сервере.
fetch_bins() {
  local arch bin="$ROOT/.cache/bin"
  [ "$(uname -s)" = Linux ] || return 1
  case "$(uname -m)" in
    x86_64) arch=amd64; asset=Xray-linux-64.zip; xs="$XRAY_SHA256_AMD64"; hs="$HYSTERIA_SHA256_AMD64" ;;
    aarch64) arch=arm64; asset=Xray-linux-arm64-v8a.zip; xs="$XRAY_SHA256_ARM64"; hs="$HYSTERIA_SHA256_ARM64" ;;
    *) return 1 ;;
  esac
  mkdir -p "$bin"
  if [ ! -x "$bin/xray-$XRAY_VERSION" ]; then
    curl -fsSL --retry 3 -o "$T/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$asset"
    [ "$(sha256sum "$T/x.zip" | cut -d' ' -f1)" = "$xs" ] || return 1
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' "$T/x.zip" "$T"
    install -m 755 "$T/xray" "$bin/xray-$XRAY_VERSION"
  fi
  if [ ! -x "$bin/hysteria-$HYSTERIA_VERSION" ]; then
    curl -fsSL --retry 3 -o "$T/h" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-$arch"
    [ "$(sha256sum "$T/h" | cut -d' ' -f1)" = "$hs" ] || return 1
    install -m 755 "$T/h" "$bin/hysteria-$HYSTERIA_VERSION"
  fi
}

# Внешний IP через локальный SOCKS.
ip_via() {
  local port="$1" url
  for url in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    if ip="$(curl -fsS -m 12 --socks5-hostname "127.0.0.1:$port" "$url" 2>/dev/null)" && [ -n "$ip" ]; then
      printf '%s' "$ip" | tr -d '[:space:]'
      return 0
    fi
  done
  return 1
}

wait_port() {
  for _ in $(seq 1 40); do
    python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(.2); sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$1" && return 0
    sleep .25
  done
  return 1
}

CLIENT_IP="$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)"
HOST_IP="$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')"
[ -n "$HOST_IP" ] || HOST_IP="$HOST"

probe() {
  local name="$1" port="$2"
  shift 2
  "$@" >"$OUT/logs/client-$name.log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  local exit_ip=""
  if wait_port "$port"; then
    sleep 1
    exit_ip="$(ip_via "$port" || true)"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ "$exit_ip" = "$HOST_IP" ] && [ "$exit_ip" != "$CLIENT_IP" ]; then
    mark "transport_$name" ok "exit_ip=$exit_ip"
  else
    mark "transport_$name" fail "exit_ip=${exit_ip:-нет ответа} ожидался $HOST_IP"
  fi
}

if [ ! -s "$OUT/client/xray-client.json" ]; then
  mark transport_reality fail "нет клиентского конфига: шаг clientcfg"
  mark transport_hysteria fail "нет клиентского конфига: шаг clientcfg"
elif ! fetch_bins; then
  mark transport_reality fail "клиентский бинарь не получен (нужен Linux)"
  mark transport_hysteria fail "клиентский бинарь не получен (нужен Linux)"
else
  probe reality 10808 "$ROOT/.cache/bin/xray-$XRAY_VERSION" run -c "$OUT/client/xray-client.json"
  probe hysteria 10809 "$ROOT/.cache/bin/hysteria-$HYSTERIA_VERSION" client -c "$OUT/client/hysteria-client.yaml"
fi

python3 "$ROOT/scripts/lib/verdict.py" "$CHECKS" "$OUT/journal.jsonl" "$HOST" "$CLIENT_IP" "$OUT/verdict.json"
rm -f "$ROOT/output/.active-deploy" "$ROOT/output/.active-deploy.blocks"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["ok"] else 1)' "$OUT/verdict.json"
