#!/usr/bin/env bash
# sbctl.sh start urltest <интервал> <tolerance> | start selector <интервал_сторожа> <объект> [предел_пробы] | stop.
# Держит pid sing-box, локальных Xray и сторожа в файлах. Журналы: /tmp/sb.log, /tmp/wd.log.
stop() {
  for f in /tmp/wd.pid /tmp/sb.pid /tmp/xr1.pid /tmp/xr4.pid; do [ -f "$f" ] && { kill -9 "$(cat "$f")" 2>/dev/null; rm -f "$f"; }; done
  return 0
}
case "$1" in
  stop) stop ;;
  start)
    stop; /opt/lab/proto.sh x down; rm -f /tmp/sb.log /tmp/wd.log
    if [ "$2" = urltest ]; then python3 /opt/lab/sb-config.py urltest "$3" "$4" http://127.0.0.1:8080/1k
    else python3 /opt/lab/sb-config.py selector; fi
    for n in xr1 xr4; do
      nohup xray run -c /tmp/$n.json >/tmp/$n.log 2>&1 </dev/null &
      echo $! > /tmp/$n.pid
    done
    nohup sing-box run -c /tmp/sb.json >/tmp/sb.out 2>&1 </dev/null &
    echo $! > /tmp/sb.pid
    if [ "$2" = selector ]; then
      sleep 1; nohup python3 /opt/lab/watchdog.py "$3" "$4" ${5:-} >/tmp/wd.log 2>&1 </dev/null &
      echo $! > /tmp/wd.pid
    fi ;;
esac
