#!/usr/bin/env python3
"""Склеивает JSON двух фаз шага в один."""
import json
import sys

a, b = (json.loads(x) for x in sys.argv[1:3])
print(json.dumps({
    "step": a["step"],
    "ok": a["ok"] and b["ok"],
    "changed": a["changed"] + b["changed"],
    "checks": {**a["checks"], **b["checks"]},
    "facts": {**a["facts"], **b["facts"]},
    "reason": " ".join(x for x in (a["reason"], b["reason"]) if x),
}, ensure_ascii=False))
