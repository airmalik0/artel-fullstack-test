#!/usr/bin/env bash
# rep.sh <протокол> <смещение>: чистый старт туннеля, 1 КиБ и 1 МиБ. Печатает поля для matrix.py.
P=$1; OFF=$2
/opt/lab/proto.sh "$P" down
s=$(date +%s.%N); /opt/lab/proto.sh "$P" up "$OFF"; rc=$?; e=$(date +%s.%N)
up=$(awk "BEGIN{printf \"%.4f\", $e-$s}")
echo "up $rc $up"
[ "$rc" = 0 ] || exit 0
echo "k1 $(/opt/lab/fetch.sh "$P" 1k 6 "$OFF")"
echo "m1 $(/opt/lab/fetch.sh "$P" 1m 14 "$OFF")"
