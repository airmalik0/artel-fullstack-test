#!/usr/bin/env python3
"""Сводка по matrix.csv: успех, медиана и размах по точке. summary.py results/matrix.csv [--md]"""
import csv, statistics as st, sys, collections
rows = list(csv.DictReader(open(sys.argv[1])))
md = "--md" in sys.argv
g = collections.OrderedDict()
for r in rows:
    g.setdefault((r["scenario"], r["proto"], r["target"]), []).append(r)
def med(v, f="{:.3g}"):
    v = [float(x) for x in v if x not in ("", None)]
    if not v:
        return "-"
    return f"{f.format(st.median(v))} [{f.format(min(v))}..{f.format(max(v))}]"
hdr = ["scenario", "proto", "target", "n", "tun_ok", "1k_ok", "1m_ok", "cold_ttfb_s", "bytes_1m", "thr_mbit", "overhead_pct", "par_ok"]
print(("| " + " | ".join(hdr) + " |\n|" + "---|" * len(hdr)) if md else ",".join(hdr))
for k, v in g.items():
    c = [k[0], k[1], k[2], str(len(v)),
         str(sum(r["tunnel_ok"] == "1" for r in v)), str(sum(r["http_1k"] == "200" for r in v)),
         str(sum(r["complete_1m"] == "1" for r in v)), med([r["cold_ttfb_s"] for r in v], "{:.3f}"),
         med([r["bytes_1m"] for r in v], "{:.0f}"), med([r["thr_mbit"] for r in v], "{:.1f}"),
         med([r["overhead_pct"] for r in v], "{:.2f}"), med([r["par_ok"] for r in v], "{:.0f}")]
    print(("| " + " | ".join(c) + " |") if md else ",".join(x.replace(",", ";") for x in c))
