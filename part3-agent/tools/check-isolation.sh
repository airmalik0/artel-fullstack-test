#!/usr/bin/env bash
# Доказывает, что запрос идёт в DeepSeek, а к Anthropic нет. Запускать под root на хосте агента:
#   sudo tools/check-isolation.sh [--no-block] [файл-отчёта]
# Домены Anthropic глушатся в /etc/hosts (с --no-block нет), задание с инструментами и подагентом
# идёт через start.sh, tcpdump пишет ClientHello, tshark достаёт из них SNI.
set -euo pipefail

BLOCK=1
if [ "${1:-}" = --no-block ]; then BLOCK=0; shift; fi
REPORT="${1:-/tmp/isolation-report.txt}"
AGENT_USER="${AGENT_USER:-agent}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "нужен root" >&2; exit 1; }
command -v tshark >/dev/null || apt-get install -y -qq --no-install-recommends tshark tcpdump >/dev/null

HOSTS_BAK="$(mktemp)"
PCAP="$(mktemp --suffix=.pcap)"
RESULT="$(mktemp)"
chmod 644 "$RESULT"
cp /etc/hosts "$HOSTS_BAK"
TD=""
cleanup() {
  [ -z "$TD" ] || kill "$TD" 2>/dev/null || true
  cp "$HOSTS_BAK" /etc/hosts
  rm -f "$HOSTS_BAK" "$PCAP" "$RESULT"
}
trap cleanup EXIT

if [ "$BLOCK" = 1 ]; then
  for d in api.anthropic.com console.anthropic.com statsig.anthropic.com claude.ai platform.claude.com; do
    echo "0.0.0.0 $d" >>/etc/hosts
  done
fi
tcpdump -i any -nn -U -w "$PCAP" 'tcp dst port 443 or udp dst port 443' >/dev/null 2>&1 &
TD=$!
sleep 1

PROMPT='Прочитай scripts/lib/versions.env инструментом Read и назови версию Xray. Затем запусти одного подагента general-purpose, пусть прочитает scripts/lib/versions.env и назовёт версию Hysteria. Ответь одной строкой: XRAY <версия> HYSTERIA <версия>.'
sudo -u "$AGENT_USER" -H bash -c "cd '$ROOT' && ./start.sh -p \"\$0\" --output-format stream-json --verbose --include-partial-messages </dev/null" "$PROMPT" \
  2>/dev/null | python3 -I -c '
import json, sys, time
first = last = None
deltas = 0
final = {}
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("type") == "stream_event" and e["event"].get("type") == "content_block_delta":
        deltas += 1
        last = time.time()
        first = first or last
    if e.get("type") == "result":
        final = e
print("потоковых дельт:", deltas, "за", round((last or 0) - (first or 0), 1), "с")
print("модели:", sorted(final.get("modelUsage", {})))
print("ответ:", str(final.get("result", ""))[:120])
print("is_error:", final.get("is_error"), "ходов:", final.get("num_turns"))
' | tee "$RESULT"

sleep 2
kill "$TD"
wait "$TD" 2>/dev/null || true
TD=""
{
  cat "$RESULT"
  echo "домены Anthropic заглушены: $([ "$BLOCK" = 1 ] && echo да || echo нет)"
  echo "SNI всех соединений за прогон:"
  tshark -r "$PCAP" -Y 'tls.handshake.extensions_server_name' \
    -T fields -e tls.handshake.extensions_server_name 2>/dev/null | sort | uniq -c
} | tee "$REPORT"
