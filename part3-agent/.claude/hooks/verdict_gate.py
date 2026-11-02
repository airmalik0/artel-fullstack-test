#!/usr/bin/env python3
"""Stop: развёртывание не заканчивается словами модели.

scripts/step.sh ставит метку output/.active-deploy на первом шаге, verdict.sh её
снимает. Пока метка есть, агент не может закончить ход: итог даёт только проверка.
Метка живёт и после отказа шага, потому что честный провал тоже оформляется
через verdict.sh. После трёх отказов отпускаем, чтобы не крутить ход вечно.
"""
import json
import os
import sys

data = json.load(sys.stdin)
root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or "."
marker = os.path.join(root, "output", ".active-deploy")
if not os.path.exists(marker):
    sys.exit(0)

with open(marker, encoding="utf-8") as fh:
    host = fh.read().strip()

counter = marker + ".blocks"
blocks = 0
if os.path.exists(counter):
    with open(counter, encoding="utf-8") as fh:
        blocks = int(fh.read().strip() or 0)
if blocks >= 3:
    sys.exit(0)
with open(counter, "w", encoding="utf-8") as fh:
    fh.write(str(blocks + 1))

print(
    json.dumps(
        {
            "decision": "block",
            "reason": (
                f"Развёртывание {host} не закрыто: нет свежего output/{host}/verdict.json. "
                f"Запусти ./scripts/verdict.sh {host}. Итог сообщай только из его вывода."
            ),
        },
        ensure_ascii=False,
    )
)
