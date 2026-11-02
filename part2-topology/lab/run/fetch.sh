#!/usr/bin/env bash
# fetch.sh <протокол> <объект> <max_time> [смещение] -> одна строка: код соединение tls ttfb всего байт скорость
P=$1; OBJ=$2; MT=$3; OFF=${4:-0}
F='%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}\n'
O=(-sS -o /dev/null -w "$F" --max-time "$MT" --connect-timeout 5 --speed-time 3 --speed-limit 256)
H=$((10 + OFF))
case "$P" in
  https-ok)      exec curl "${O[@]}" -k --resolve "other.example:443:10.10.2.$H"   "https://other.example/$OBJ" 2>/dev/null ;;
  https-wl)      exec curl "${O[@]}" -k --resolve "allowed.example:443:10.10.2.$H" "https://allowed.example/$OBJ" 2>/dev/null ;;
  https-blocked) exec curl "${O[@]}" -k --resolve "blocked.example:443:10.10.2.$H" "https://blocked.example/$OBJ" 2>/dev/null ;;
  wg)            exec curl "${O[@]}" "http://10.99.1.1:8080/$OBJ" 2>/dev/null ;;
  awg)           exec curl "${O[@]}" "http://10.99.2.1:8080/$OBJ" 2>/dev/null ;;
  ovpn-udp)      exec curl "${O[@]}" "http://10.99.3.1:8080/$OBJ" 2>/dev/null ;;
  ovpn-tcp)      exec curl "${O[@]}" "http://10.99.4.1:8080/$OBJ" 2>/dev/null ;;
  *)             exec curl "${O[@]}" --socks5-hostname 127.0.0.1:10801 "http://127.0.0.1:8080/$OBJ" 2>/dev/null ;;
esac
