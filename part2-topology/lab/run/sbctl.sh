#!/usr/bin/env bash
# sbctl.sh start <url> <интервал> [selector <объект>] | stop. Запускает sing-box и сторож, держит их pid в файлах.
stop() {
  for f in /tmp/wd.pid /tmp/sb.pid; do [ -f "$f" ] && { kill -9 "$(cat "$f")" 2>/dev/null; rm -f "$f"; }; done
  return 0
}
case "$1" in
  stop) stop ;;
  start)
    stop; /opt/lab/proto.sh x down
    python3 /opt/lab/sb-config.py "$2" "$3" ${4:+selector}
    nohup sing-box run -c /tmp/sb.json >/tmp/sb.log 2>&1 &
    echo $! > /tmp/sb.pid
    if [ "${4:-}" = selector ]; then
      sleep 1; nohup python3 /opt/lab/watchdog.py 5 "$5" >/tmp/wd.log 2>&1 &
      echo $! > /tmp/wd.pid
    fi ;;
esac
