#!/usr/bin/env python3
"""Проверки своего дроплета через публичный API check-host.net. Умеренно: 3 круга по 8 проверок,
пауза 20 с между проверками, опрос результата не больше 3 раз на проверку.
run.py <ip> <каталог_вывода>"""
import json, sys, time, urllib.parse, urllib.request
IP, OUT = sys.argv[1], sys.argv[2]
H = IP.replace(".", "-") + ".sslip.io"
NODES = ["ru1", "ru2", "de4", "nl1", "us1"]
CHECKS = [("http", f"https://{H}/big"), ("http", f"http://{IP}/big"), ("tcp", f"{IP}:443"), ("tcp", f"{IP}:80"),
          ("tcp", f"{IP}:22"), ("ping", IP), ("udp", f"{IP}:51820"), ("udp", f"{IP}:443")]
def get(u):
    r = urllib.request.Request(u, headers={"Accept": "application/json", "User-Agent": "artel-test-measure/1"})
    return json.load(urllib.request.urlopen(r, timeout=30))
reqs = 0; log = open(f"{OUT}/results.jsonl", "a", buffering=1)
for rnd in range(1, 4):
    for typ, host in CHECKS:
        q = urllib.parse.urlencode([("host", host)] + [("node", f"{n}.node.check-host.net") for n in NODES])
        t0 = time.time()
        try:
            s = get(f"https://check-host.net/check-{typ}?{q}"); reqs += 1
        except Exception as e:
            log.write(json.dumps(dict(round=rnd, type=typ, host=host, error=str(e))) + "\n"); time.sleep(30); continue
        res = {}
        for _ in range(3):
            time.sleep(12)
            res = get(f"https://check-host.net/check-result/{s['request_id']}"); reqs += 1
            if all(v is not None for v in res.values()):
                break
        log.write(json.dumps(dict(round=rnd, type=typ, host=host, t0=t0, request_id=s["request_id"], nodes=s.get("nodes"), result=res)) + "\n")
        time.sleep(20)
print("requests", reqs)
