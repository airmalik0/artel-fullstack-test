#!/usr/bin/env bash
# Поднимает адреса и все сервисы на server. Запускать после каждой загрузки ВМ.
set -uo pipefail
D=/etc/lab
for i in lanb; do ethtool -K $i tso off gso off gro off lro off >/dev/null 2>&1; done
for i in 10 11 12 13 14 15 16 17 18 19; do
  ip addr add 10.10.2.$i/24 dev lanb 2>/dev/null
  ip addr add 10.10.2.$((i+200))/24 dev lanb 2>/dev/null
done
# Адреса .210-.218: те же сервисы, но вне множества «зарубежный хостинг» модели.
nft -f - <<N
table ip labnat { }
flush table ip labnat
table ip labnat {
  chain pre { type nat hook prerouting priority -100;
    ip daddr 10.10.2.210-10.10.2.219 dnat to ip daddr map { $(for i in 10 11 12 13 14 15 16 17 18 19; do printf '10.10.2.%d : 10.10.2.%d, ' $((i+200)) $i; done) }
  }
}
N
for p in nginx xray hysteria openvpn amneziawg-go; do pids=$(pgrep -x "$p" | tr '\n' ' '); [ -n "$pids" ] && kill $pids 2>/dev/null; done
sleep 1; ip link del wg0 2>/dev/null; ip link del awg0 2>/dev/null
nginx -c $D/nginx.conf
nohup xray run -c $D/xray-server.json >/var/log/lab-xray.log 2>&1 &
HYSTERIA_DISABLE_UPDATE_CHECK=1 nohup hysteria server -c $D/hy-plain.yaml >/var/log/lab-hy-plain.log 2>&1 &
HYSTERIA_DISABLE_UPDATE_CHECK=1 nohup hysteria server -c $D/hy-obfs.yaml >/var/log/lab-hy-obfs.log 2>&1 &
openvpn --config $D/ovpn-udp.conf --daemon --log /var/log/lab-ovpn-udp.log
openvpn --config $D/ovpn-tcp.conf --daemon --log /var/log/lab-ovpn-tcp.log
ip link add wg0 type wireguard; wg setconf wg0 $D/wg.conf; ip addr add 10.99.1.1/24 dev wg0; ip link set wg0 up
amneziawg-go awg0 >/var/log/lab-awg.log 2>&1
sleep 1; awg setconf awg0 $D/awg.conf; ip addr add 10.99.2.1/24 dev awg0; ip link set awg0 up
sleep 1; ss -lntup | awk 'NR>1{print $1,$5,$7}' | grep -v ':22 ' | sort | cut -c1-70
