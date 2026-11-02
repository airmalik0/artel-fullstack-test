#!/usr/bin/env bash
# Намеренный сбой на цели для проверки агента. Запускает человек, агенту не разрешён.
#   tools/inject-fault.sh <host> stop-xray    xray остановлен и выключен из автозапуска
#   tools/inject-fault.sh <host> busy-tcp443  xray снят, чужая служба занимает TCP/443
#   tools/inject-fault.sh <host> drop-udp-rule  из файрвола удалено правило 443/udp
#   tools/inject-fault.sh <host> clear        убрать чужую службу
set -euo pipefail
. "$(dirname "$0")/../scripts/lib/common.sh"
load_target "${1:-}"
pick_login || { echo "нет входа на $HOST" >&2; exit 1; }
case "${2:-}" in
  stop-xray) remote_sh <<<'systemctl disable --now xray 2>&1 | tail -1; systemctl is-active xray || true' ;;
  busy-tcp443) remote_sh <<'REMOTE'
systemctl disable --now xray 2>&1 | tail -1
systemd-run --unit=fake-web --collect python3 -m http.server 443 --bind 0.0.0.0 >/dev/null 2>&1
sleep 2
ss -H -ltnp 'sport = :443' | cut -c1-100
REMOTE
    ;;
  drop-udp-rule) remote_sh <<<'ufw delete allow 443/udp; ufw status | grep -c "443/udp" || true' ;;
  clear) remote_sh <<<'systemctl stop fake-web 2>/dev/null; echo cleared' ;;
  *) echo "сбои: stop-xray busy-tcp443 drop-udp-rule clear" >&2; exit 2 ;;
esac
