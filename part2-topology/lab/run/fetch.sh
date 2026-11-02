#!/usr/bin/env bash
# fetch.sh <протокол> <объект> <max_time> [смещение] -> одна строка: код соединение tls ttfb всего байт скорость
# INNER=https: внутри туннеля HTTPS с тремя запросами и длинными заголовками, как у браузера (сценарий fet_ru).
P=$1; OBJ=$2; MT=$3; OFF=${4:-0}; F='%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}\n'
O=(-sS -o /dev/null -w "$F" --max-time "$MT" --connect-timeout 5 --speed-time 3 --speed-limit 256)
H=$((10 + OFF)); X=()
case "$P" in
  https-ok)      O+=(-k --resolve "other.example:443:10.10.2.$H");   U="https://other.example" ;;
  https-wl)      O+=(-k --resolve "allowed.example:443:10.10.2.$H"); U="https://allowed.example" ;;
  https-blocked) O+=(-k --resolve "blocked.example:443:10.10.2.$H"); U="https://blocked.example" ;;
  wg)            U="http://10.99.1.1:8080"; I="https://10.99.1.1:8444" ;;
  awg)           U="http://10.99.2.1:8080"; I="https://10.99.2.1:8444" ;;
  ovpn-udp)      U="http://10.99.3.1:8080"; I="https://10.99.3.1:8444" ;;
  ovpn-tcp)      U="http://10.99.4.1:8080"; I="https://10.99.4.1:8444" ;;
  *)             O+=(--socks5-hostname 127.0.0.1:10801); U="http://127.0.0.1:8080"; I="https://127.0.0.1:8443" ;;
esac
if [ "${INNER:-}" = https ] && [ -n "${I:-}" ]; then
  PAD=$(head -c 450 /dev/urandom | base64 -w0)
  O=("${O[@]}" -k --http1.1 -H "Cookie: $PAD" --parallel-max 1)
  # Первые запросы дают клиентские пакеты больше 411 байт, основной идёт последним в том же соединении.
  W=$(curl "${O[@]}" "$I/1k" -o /dev/null "$I/1k" -o /dev/null "$I/1k" -o /dev/null "$I/$OBJ" -o /dev/null 2>/dev/null)
  echo "$W" | tail -1
else
  exec curl "${O[@]}" "$U/$OBJ" 2>/dev/null
fi
