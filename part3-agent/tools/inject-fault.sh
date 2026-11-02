#!/usr/bin/env bash
# Намеренный сбой на цели для проверки агента. Запускает человек, агенту не разрешён.
#   tools/inject-fault.sh <host> stop-xray    xray остановлен и выключен из автозапуска
#   tools/inject-fault.sh <host> busy-tcp443  xray снят, чужая служба занимает TCP/443
#   tools/inject-fault.sh <host> drop-udp-rule  из файрвола удалено правило 443/udp
#   tools/inject-fault.sh <host> drop-alt-rule  из файрвола удалено правило второго Reality
#   tools/inject-fault.sh <host> clear        убрать чужую службу
set -euo pipefail
. "$(dirname "$0")/../scripts/lib/common.sh"
load_target "${1:-}"
pick_login || { echo "нет входа на $HOST" >&2; exit 1; }
case "${2:-}" in
  stop-xray) remote_sh <<<'systemctl disable --now xray 2>&1 | tail -1; systemctl is-active xray || true' ;;
  busy-tcp443) remote_sh <<'REMOTE'
systemctl disable --now xray 2>&1 | tail -1
# Чужой слушатель: принимает соединение и закрывает, файлов не отдаёт.
systemd-run --unit=fake-web --collect -p DynamicUser=yes \
  -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p CapabilityBoundingSet=CAP_NET_BIND_SERVICE \
  -p ProtectSystem=strict -p ProtectHome=true -p PrivateTmp=true \
  python3 -I -c 'import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 443))
s.listen(16)
while True:
    conn, _ = s.accept()
    conn.close()' >/dev/null 2>&1
sleep 2
ss -H -ltnp 'sport = :443' | cut -c1-100
REMOTE
    ;;
  drop-udp-rule) remote_sh <<<'ufw delete allow 443/udp; ufw status | grep -c "443/udp" || true' ;;
  clear) remote_sh <<<'systemctl stop fake-web 2>/dev/null; echo cleared' ;;
  drop-alt-rule) remote_sh <<<"ufw delete allow $REALITY_ALT_PORT/tcp; ufw status | grep -c '$REALITY_ALT_PORT/tcp' || true" ;;
  *) echo "сбои: stop-xray busy-tcp443 drop-udp-rule drop-alt-rule clear" >&2; exit 2 ;;
esac
