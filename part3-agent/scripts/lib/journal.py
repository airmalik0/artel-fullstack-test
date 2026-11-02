#!/usr/bin/env python3
"""Дописывает итог шага в журнал прогона: ok и список изменений."""
import datetime
import json
import sys

result = json.load(sys.stdin)
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "step": result["step"],
    "ok": result["ok"],
    "changed": result["changed"],
}
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
