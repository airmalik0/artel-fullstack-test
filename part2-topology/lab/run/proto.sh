#!/usr/bin/env bash
# Клиент: поднять/снять туннель. proto.sh <протокол> up|down [смещение_адреса: 0 или 100]
# Коды выхода up: 0 туннель готов, 3 не поднялся за отведённое время.
P=$1; A=$2; OFF=${3:-0}; C=/etc/lab
hostip() { echo "10.10.2.$(( $1 + OFF ))"; }
sub() { sed "s/@H@/$(hostip "$2")/" "$C/$1"; }
waitport() { for _ in $(seq 1 40); do ss -lnt | grep -q '127.0.0.1:10801' && return 0; sleep 0.05; done; return 3; }
stopall() {
  for n in xray hysteria openvpn amneziawg-go; do pids=$(pgrep -x "$n" | tr '\n' ' '); [ -n "$pids" ] && kill -9 $pids 2>/dev/null; done
  ip link del wg0 2>/dev/null; ip link del awg0 2>/dev/null; ip link del tun0 2>/dev/null
  rm -f /var/run/amneziawg/awg0.sock
  return 0
}
[ "$A" = down ] && { stopall; exit 0; }
case "$P" in
  https-*) exit 0 ;;
  reality|reality-wl|reality-mux|xhttp|ss2022)
    case "$P" in reality|reality-wl) o=11;; reality-mux) o=19;; xhttp) o=12;; ss2022) o=13;; esac
    sub "xray-$P.json" $o > /tmp/x.json; nohup xray run -c /tmp/x.json >/tmp/xray.log 2>&1 &
    waitport ;;
  hy2|hy2-blk|hy2-obfs)
    case "$P" in hy2) f=plain;o=11;; hy2-blk) f=blk;o=11;; hy2-obfs) f=obfs;o=18;; esac
    sub "hy-$f.yaml" $o > /tmp/h.yaml; HYSTERIA_DISABLE_UPDATE_CHECK=1 nohup hysteria client -c /tmp/h.yaml >/tmp/hy.log 2>&1 &
    # Клиент Hysteria поднимает socks только после рукопожатия QUIC.
    for _ in $(seq 1 120); do ss -lnt | grep -q '127.0.0.1:10801' && exit 0; sleep 0.05; done; exit 3 ;;
  wg)
    sub wg.conf 14 > /tmp/wg.conf; ip link add wg0 type wireguard; wg setconf wg0 /tmp/wg.conf
    ip addr add 10.99.1.2/24 dev wg0; ip link set wg0 up ;;
  awg)
    sub awg.conf 15 > /tmp/awg.conf; amneziawg-go awg0 >/tmp/awg.log 2>&1
    for _ in $(seq 1 40); do [ -S /var/run/amneziawg/awg0.sock ] && break; sleep 0.05; done
    awg setconf awg0 /tmp/awg.conf; ip addr add 10.99.2.2/24 dev awg0; ip link set awg0 up ;;
  ovpn-udp|ovpn-tcp)
    if [ "$P" = ovpn-udp ]; then o=16; else o=17; fi
    sub "$P.conf" $o > /tmp/o.conf; nohup openvpn --config /tmp/o.conf >/tmp/ovpn.log 2>&1 &
    for _ in $(seq 1 100); do grep -q 'Initialization Sequence Completed' /tmp/ovpn.log 2>/dev/null && exit 0; sleep 0.1; done; exit 3 ;;
  *) echo "unknown $P" >&2; exit 2 ;;
esac
