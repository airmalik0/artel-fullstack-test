#!/usr/bin/env bash
# Отпечаток состояния цели, независимый от отчёта шагов: конфиги, правила файрвола,
# время запуска служб, настройки sysctl. Два одинаковых вывода значат, что между
# ними на сервере ничего не менялось и службы не перезапускались.
#   tools/state-hash.sh <host>
set -euo pipefail
. "$(dirname "$0")/../scripts/lib/common.sh"
load_target "${1:-}"
pick_login || { echo "нет входа на $HOST" >&2; exit 1; }
remote_sh <<'REMOTE'
export LC_ALL=C
{
  sha256sum /etc/xray/* /etc/hysteria/* /etc/ssh/sshd_config.d/* /etc/sudoers.d/* \
    /etc/sysctl.d/90-vpn-node.conf /etc/systemd/system/xray.service /etc/systemd/system/hysteria.service \
    /usr/local/bin/xray /usr/local/bin/hysteria /etc/apt/apt.conf.d/20auto-upgrades
  ufw status verbose
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
  sha256sum /var/lib/dpkg/status
} | sha256sum | cut -c1-16
for u in xray hysteria ssh; do
  printf '%s %s\n' "$u" "$(systemctl show "$u" -p ActiveEnterTimestampMonotonic --value)"
done
REMOTE
