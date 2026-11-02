#!/usr/bin/env bash
# probeloop.sh <секунд> <объект> <байт>: запрос каждые 0.25 с, строка: время ok.
D=$1; OBJ=$2; WANT=$3; E=$(( $(date +%s) + D ))
while [ "$(date +%s)" -lt "$E" ]; do
  t=$(date +%s.%N)
  s=$(curl -s -o /dev/null -w '%{size_download}' --max-time 1.5 --socks5-hostname 127.0.0.1:10801 "http://127.0.0.1:8080/$OBJ")
  [ "$s" = "$WANT" ] && echo "$t 1" || echo "$t 0"
  sleep 0.25
done
