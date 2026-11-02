#!/usr/bin/env bash
# parallel.sh <протокол> <n> [смещение]: n одновременных запросов 256k, печатает число успешных.
P=$1; N=$2; OFF=${3:-0}
t=$(mktemp -d)
for i in $(seq 1 "$N"); do ( /opt/lab/fetch.sh "$P" 256k 12 "$OFF" > "$t/$i" ) & done
wait
ok=0; for i in $(seq 1 "$N"); do s=$(awk '{print $6}' "$t/$i"); [ "${s:-0}" = 262144 ] && ok=$((ok+1)); done
rm -rf "$t"; echo "$ok"
