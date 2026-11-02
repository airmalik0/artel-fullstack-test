#!/usr/bin/env bash
# Развёртывание без участия человека: ./deploy.sh <host>
# Код возврата берётся из verdict.json, а не из текста модели.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
HOST="${1:?использование: ./deploy.sh <host>}"
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "недопустимый host" >&2; exit 2; }
mkdir -p "output/$HOST"
rm -f "output/$HOST/verdict.json"
./start.sh -p "/deploy-server $HOST" --output-format json </dev/null >"output/$HOST/agent-run.json" || true
python3 - "$HOST" <<'PY'
import json, sys
host = sys.argv[1]
run = json.load(open(f"output/{host}/agent-run.json"))
print("модели:", ", ".join(sorted(run.get("modelUsage", {}))) or "нет данных")
print("итог агента:", str(run.get("result", ""))[:600])
try:
    verdict = json.load(open(f"output/{host}/verdict.json"))
except FileNotFoundError:
    print("verdict.json нет: развёртывание не подтверждено")
    sys.exit(1)
print("verdict ok:", verdict["ok"], "changed:", verdict["changed_this_run"])
sys.exit(0 if verdict["ok"] else 1)
PY
