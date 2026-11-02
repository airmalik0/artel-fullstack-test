#!/usr/bin/env python3
"""Настоящий период проверки urltest из журналов sing-box, которые оставил failover.py: разница между соседними успешными
пробами запасного пути exit2, точность журнала 1 с. fo-period.py > results/urltest-period.csv"""
import datetime as dt, glob, os, re
RAW = os.path.expanduser("~/artel-lab/raw/fo")
print("interval_s,log,gap_s")
for pre, iv in (("urltest15", 15), ("urltest5", 5)):
    for f in sorted(glob.glob(f"{RAW}/{pre}_*.log")):
        ts = [dt.datetime.strptime(m, "%H:%M:%S") for m in re.findall(r"(\d\d:\d\d:\d\d) DEBUG outbound/urltest\[auto\]: outbound exit2 available", open(f).read())]
        for a, b in zip(ts, ts[1:]):
            print(f"{iv},{os.path.basename(f)},{(b - a).total_seconds():.0f}")
