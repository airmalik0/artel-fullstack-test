#!/usr/bin/env python3
"""Чистый Hysteria2 на адресе вне хостинга при выключенной модели: сколько из 20 загрузок 1 МиБ проходит через DNAT на ВМ.
Нужно, чтобы отделить артефакт стенда от правила. ruhost-hy2.py results/ruhost-hy2.csv [повторов]"""
import csv, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
sys.argv, args = sys.argv[:1], sys.argv[1:]
import matrix as m
N = int(args[1]) if len(args) > 1 else 20
f = open(args[0], "w", newline=""); w = csv.writer(f); w.writerow(["proto", "target", "rep", "tunnel_ok", "http_1k", "complete_1m", "bytes_1m"])
m.ssh("tspu", "sudo /opt/lab/ctl.py net; sudo /opt/lab/ctl.py set off")
for p, t, n in (("hy2", "ruhost", N), ("hy2", "foreign", 5), ("hy2-obfs", "ruhost", N)):
    ok = 0
    for r in range(n):
        x = m.one("off", p, t, r); ok += int(x["complete_1m"])
        w.writerow([p, t, r, x["tunnel_ok"], x["http_1k"], x["complete_1m"], x["bytes_1m"]]); f.flush()
    print(p, t, ok, "из", n, flush=True)
