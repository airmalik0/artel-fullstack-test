#!/usr/bin/env python3
"""Чистый Hysteria2 на адресе вне хостинга при выключенной модели: сколько из 20 загрузок 1 МиБ проходит через DNAT на ВМ.
Нужно, чтобы отделить артефакт стенда от правила. ruhost-hy2.py results/ruhost-hy2.csv [повторов]"""
import csv, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
sys.argv, args = sys.argv[:1], sys.argv[1:]
import matrix as m
N = int(args[1]) if len(args) > 1 else 20
w = csv.writer(open(args[0], "w", newline="")); w.writerow(["proto", "target", "rep", "tunnel_ok", "http_1k", "complete_1m", "bytes_1m"])
m.ssh("tspu", "sudo /opt/lab/ctl.py net; sudo /opt/lab/ctl.py set off")
for p in ("hy2", "hy2-obfs"):
    for t in ("ruhost", "foreign"):
        ok = 0
        for r in range(N):
            x = m.one("off", p, t, r); ok += x["complete_1m"] == 1 or x["complete_1m"] == "1"
            w.writerow([p, t, r, x["tunnel_ok"], x["http_1k"], x["complete_1m"], x["bytes_1m"]])
        print(p, t, ok, "из", N, flush=True)
