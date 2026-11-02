#!/usr/bin/env bash
# Сервер на время замера переключения: на 10.10.2.11 Hysteria2 с Salamander вместо чистого,
# как на выходе A. fo-server.sh ensure | xray-stop | restore. restore возвращает набор для матрицы.
D=/etc/lab
export HYSTERIA_DISABLE_UPDATE_CHECK=1
hp() { pgrep -f -- "hysteria server -c $D/$1"; }
start_hy() { nohup hysteria server -c "$D/$1" >"/var/log/lab-$1.log" 2>&1 </dev/null & }
start_xray() { pgrep -x xray >/dev/null || { nohup xray run -c "$D/xray-server.json" >/var/log/lab-xray.log 2>&1 </dev/null & }; }
case "$1" in
  ensure)
    p=$(hp hy-plain.yaml); [ -n "$p" ] && { kill $p; sleep 0.3; }
    [ -n "$(hp hy-obfsa.yaml)" ] || start_hy hy-obfsa.yaml
    start_xray ;;
  xray-stop) kill "$(pgrep -x xray)" ;;
  restore)
    p=$(hp hy-obfsa.yaml); [ -n "$p" ] && { kill $p; sleep 0.3; }
    [ -n "$(hp hy-plain.yaml)" ] || start_hy hy-plain.yaml
    start_xray ;;
esac
