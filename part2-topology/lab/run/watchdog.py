#!/usr/bin/env python3
"""Сторож объёма: каждые INTERVAL секунд качает через текущий выход объект больше порога «занавеса»
и переключает selector sing-box на следующий выход, если объект не докачался. watchdog.py <интервал> <объект>"""
import json, subprocess, sys, time, urllib.request
INTERVAL, OBJ = float(sys.argv[1]), sys.argv[2]
ORDER = ["reality", "hy2", "exit2"]
def api(m, path, body=None):
    r = urllib.request.Request("http://127.0.0.1:9090" + path, method=m, data=body and json.dumps(body).encode())
    return urllib.request.urlopen(r, timeout=2).read()
cur = 0
while True:
    time.sleep(INTERVAL)
    c = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{size_download}", "--max-time", "4", "--speed-time", "2", "--speed-limit", "1024",
                        "--socks5-hostname", "127.0.0.1:10801", f"http://127.0.0.1:8080/{OBJ}"], capture_output=True, text=True)
    want = {"256k": 262144, "1k": 1024}[OBJ]
    if c.stdout.strip() != str(want):
        cur = (cur + 1) % len(ORDER)
        api("PUT", "/proxies/auto", {"name": ORDER[cur]})
        subprocess.run(["curl", "-s", "-X", "DELETE", "http://127.0.0.1:9090/connections"], capture_output=True)
