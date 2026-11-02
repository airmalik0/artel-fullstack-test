#!/usr/bin/env python3
"""Таблицы для TOPOLOGY.md, раздел 8.3, из results/failover.csv и results/watchdog.csv. fotable.py <failover.csv> <watchdog.csv>"""
import collections, csv, statistics as st, sys
fmt = lambda x: f"{st.median(x):.1f} [{min(x):.1f}..{max(x):.1f}]"
num = lambda v: [float(i) for i in v if i != ""]
M = {"urltest15": "urltest 15 с", "urltest5": "urltest 5 с", "watchdog5": "сторож 5 с"}
print("| механизм | отказ | n | куда ушёл | до первого успеха через запасной путь, с | разрыв в работе, с | запросов потеряно |\n|---|---|---|---|---|---|---|")
g = collections.OrderedDict()
for r in csv.DictReader(open(sys.argv[1])):
    g.setdefault(r["case"], []).append(r)
for k, v in g.items():
    ok = [r for r in v if r["valid"] == "1"]
    if not ok:
        print(f"| {k} | нет действительных строк из {len(v)} | | | | | |"); continue
    sw = num(r["first_ok_fallback_s"] for r in ok)
    paths = "+".join(f"{p} {n}" for p, n in collections.Counter(r["fallback_path"] or "нет" for r in ok).most_common())
    mech = M[ok[0]["mech"] + ok[0]["interval_s"]]
    print(f"| {mech} | {ok[0]['fault']} | {len(ok)} | {paths} | "
          f"{fmt(sw) if sw else 'нет за ' + ok[0]['window_s']} | {fmt(num(r['gap_s'] for r in ok)) if sw else '-'} | "
          f"{fmt(num(r['failed_after'] for r in ok)).replace('.0', '')} |")
print(f"\nстрок всего {sum(map(len, g.values()))}, недействительных {sum(r['valid'] != '1' for v in g.values() for r in v)}, "
      f"загрузка мака {min(float(r['load1']) for v in g.values() for r in v):.0f}..{max(float(r['load1']) for v in g.values() for r in v):.0f}")
w = list(csv.DictReader(open(sys.argv[2])))
print("\n| случай | n | первое переключение, с | до первого успеха 256 КиБ, с | цепочка путей |\n|---|---|---|---|---|")
for k in ("wd_curtain_tls", "wd_curtain_all", "limit30_curtain_tls", "limit30_ip_ban"):
    ok = [r for r in w if r["case"] == k and r["valid"] == "1"]
    if ok:
        tr = "; ".join(f"{p} {n}" for p, n in collections.Counter(r["trail"] for r in ok).most_common())
        sw, fb = num(r["first_switch_s"] for r in ok), num(r["first_ok_fallback_s"] for r in ok)
        print(f"| {k} | {len(ok)} | {fmt(sw) if sw else 'нет'} | {fmt(fb) if fb else 'нет'} | {tr} |")
print("\n| канал | минут | проб | неудачных | переключений | проба, медиана, с | проба, макс, с |\n|---|---|---|---|---|---|---|")
for r in w:
    if r["case"].startswith(("clean", "rate", "limit30_rate")):
        print(f"| {r['case']} | {int(r['duration_s']) / 60:.0f} | {r['probes']} | {r['probe_fail']} | {r['switches']} | {r['probe_med_s']} | {r['probe_max_s']} |")
