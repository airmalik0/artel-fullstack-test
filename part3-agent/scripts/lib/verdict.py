#!/usr/bin/env python3
"""Собирает verdict.json из проверок и журнала текущего прогона и печатает его."""
import datetime
import json
import os
import sys

checks_path, journal_path, host, client_ip, out_path = sys.argv[1:6]

checks = {}
with open(checks_path, encoding="utf-8") as fh:
    for line in fh:
        name, status, detail = (line.rstrip("\n").split("\t") + [""])[:3]
        checks[name] = {"status": status, "detail": detail}

# Прогон начинается с последнего recon.
run = []
if os.path.exists(journal_path):
    with open(journal_path, encoding="utf-8") as fh:
        for line in fh:
            entry = json.loads(line)
            if entry.get("run_start"):
                run = []
            elif entry["step"] != "verify":
                run.append(entry)

verdict = {
    "host": host,
    "ok": bool(checks) and all(c["status"] == "ok" for c in checks.values()),
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "client_ip": client_ip,
    "checks": checks,
    "steps_this_run": [{"step": e["step"], "ok": e["ok"], "changed": len(e["changed"])} for e in run],
    "changed_this_run": sum(len(e["changed"]) for e in run),
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(verdict, fh, ensure_ascii=False, indent=2)
print(json.dumps(verdict, ensure_ascii=False))
