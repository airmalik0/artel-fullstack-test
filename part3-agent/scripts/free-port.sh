#!/bin/bash
# Снимает чужой процесс с порта узла: ./scripts/free-port.sh <host> <tcp|udp> <port>
# Службу останавливает и выключает, одиночный процесс завершает. xray, hysteria и
# sshd не трогает. Печатает JSON с тем, что снято.
set -euo pipefail
. "${0%/*}/lib/common.sh"
load_target "${1:-}"
proto="${2:-}"
port="${3:-}"
[[ "$proto" =~ ^(tcp|udp)$ ]] || { echo "протокол: tcp или udp" >&2; exit 2; }
{ [ "$port" = 443 ] || { [ "$proto" = tcp ] && [ "$port" = "$REALITY_ALT_PORT" ]; }; } \
  || { echo "снимать можно только порты узла: 443 и tcp/$REALITY_ALT_PORT" >&2; exit 2; }
pick_login || { echo '{"ok":false,"reason":"нет входа"}'; exit 1; }

remote_sh <<REMOTE
export LC_ALL=C
flag=-ltnp; [ "$proto" = udp ] && flag=-lunp
line="\$(ss -H \$flag "sport = :$port" | head -1)"
if [ -z "\$line" ]; then echo '{"ok":true,"stopped":null,"note":"порт свободен"}'; exit 0; fi
name="\$(printf '%s' "\$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')"
pid="\$(printf '%s' "\$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
case "\$name" in
  xray|hysteria|sshd) echo "{\"ok\":false,\"reason\":\"\$name не снимается\"}"; exit 1 ;;
esac
unit="\$(ps -o unit= -p "\$pid" | tr -d ' ')"
case "\$unit" in
  *.service) systemctl disable --now "\$unit" >/dev/null 2>&1 ;;
  *) kill "\$pid" ;;
esac
sleep 2
if [ -n "\$(ss -H \$flag "sport = :$port")" ]; then
  echo "{\"ok\":false,\"reason\":\"порт занят после снятия\",\"holder\":\"\$name\"}"; exit 1
fi
echo "{\"ok\":true,\"stopped\":\"\$name\",\"unit\":\"\$unit\"}"
REMOTE
