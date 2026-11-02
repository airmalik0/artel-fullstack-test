#!/usr/bin/env python3
"""Таблица РФ против контроля DE и разрезы по сетям из сохранённых JSON. Пишет summary.csv в этот каталог."""
import csv, json
L = lambda n: json.load(open(n))["result"]
ru = {x["test_name"]: x for x in L("by_test.json")}; de = {x["test_name"]: x for x in L("control_DE_by_test.json")}
share = lambda x: 100 * (x["anomaly_count"] + x["confirmed_count"]) / x["measurement_count"] if x and x["measurement_count"] else None
with open("summary.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow("test_name ru_n ru_anomaly_pct de_n de_anomaly_pct".split())
    for t, x in sorted(ru.items(), key=lambda kv: -kv[1]["measurement_count"]):
        d = de.get(t); a = share(x); b = share(d)
        w.writerow([t, x["measurement_count"], f"{a:.1f}", d["measurement_count"] if d else "", f"{b:.1f}" if b is not None else ""])
r = L("by_asn_webconn.json"); s = sorted(r, key=lambda x: -x["measurement_count"])
print("web_connectivity сетей", len(r), "всего", sum(x["measurement_count"] for x in r))
v = sorted(share(x) for x in s[:50]); print("топ-50 сетей, доля аномалий: мин", round(v[0], 1), "медиана", round(v[25], 1), "макс", round(v[-1], 1))
d = L("by_day_webconn.json"); v = [share(x) for x in d]; print("по дням:", round(min(v), 1), "..", round(max(v), 1))
print("openvpn по странам: аномалий 100% в", sum(1 for x in L("control_openvpn_by_cc.json") if x["anomaly_count"] == x["measurement_count"]), "из", len(L("control_openvpn_by_cc.json")))
