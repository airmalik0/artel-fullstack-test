#!/usr/bin/env python3
"""Сверка TOPOLOGY.md с данными: каждая строка таблиц из table.py и fotable.py должна стоять в документе дословно,
числа в тексте разделов 8.2-8.4 пересчитываются из CSV. Выход 0, если расхождений нет. check-numbers.py"""
import collections, csv, os, statistics as st, subprocess, sys
LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); DOC = open(f"{LAB}/../TOPOLOGY.md", encoding="utf8").read()
R = f"{LAB}/results"; bad = 0; seen = 0
def has(text, where):
    global bad, seen
    seen += 1
    if text not in DOC:
        bad += 1; print(f"РАСХОЖДЕНИЕ [{where}]: {text[:150]}")
def lines(cmd):
    return [l for l in subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.splitlines() if l.startswith("| ") and not l.startswith("| сценарий |")]
for l in lines([sys.executable, f"{LAB}/run/table.py", f"{R}/matrix.csv"]):
    has(l, "table.py")
if os.path.exists(f"{R}/failover.csv") and os.path.exists(f"{R}/watchdog.csv"):
    for l in lines([sys.executable, f"{LAB}/run/fotable.py", f"{R}/failover.csv", f"{R}/watchdog.csv"]):
        has(l, "fotable.py")
m = list(csv.DictReader(open(f"{R}/matrix.csv")))
has(f"Всего {len(m)} строк", "matrix.csv")
p = list(csv.DictReader(open(f"{R}/proof.csv")))
pairs = len({(r["scenario"], r["proto"]) for r in p}); okp = len({(r["scenario"], r["proto"]) for r in p}) - len({(r["scenario"], r["proto"]) for r in p if r["verdict"] != "ok"})
has(f"Итог: {okp} из {pairs}", "proof.csv")
if os.path.exists(f"{R}/proof-rebuild.csv"):
    q = list(csv.DictReader(open(f"{R}/proof-rebuild.csv")))
    has(f"{len({(r['scenario'], r['proto']) for r in q}) - len({(r['scenario'], r['proto']) for r in q if r['verdict'] != 'ok'})} из {len({(r['scenario'], r['proto']) for r in q})}", "proof-rebuild.csv")
# текст раздела 8.2
th = lambda sc, ps: [float(r["thr_mbit"]) for r in m if r["scenario"] == sc and r["target"] == "foreign" and r["proto"] in ps and r["thr_mbit"]]
four = ("https-ok", "reality", "xhttp", "ss2022"); a, b = th("off", four), th("pass", four)
has(f"вместе медиана {st.median(a):.0f} Мбит/с в контроле и {st.median(b):.0f} Мбит/с в `pass`, размах {min(a):.0f}-{max(a):.0f} и {min(b):.0f}-{max(b):.0f}", "matrix.csv")
c = th("off", ("https-ok", "https-blocked", "https-wl", "ss2022", "reality", "reality-wl", "reality-mux", "xhttp"))
has(f"разбросана от {min(c):.0f} до {max(c):.0f} Мбит/с", "matrix.csv")
w = [float(r["wire_rx_1m"]) / 1000 for r in m if r["scenario"] == "curtain_tls" and r["target"] == "foreign" and r["complete_1m"] == "0" and r["http_1k"] == "200"]
has(f"на проводе {min(w):.0f}-{max(w):.0f} КБ", "matrix.csv")
base = st.median(float(r["overhead_pct"]) for r in m if r["scenario"] == "off" and r["proto"] == "https-ok")
has(f"это {base:.2f} %".replace(".", ","), "matrix.csv")
# раздел 8.3 и выбор клиента
per = list(csv.DictReader(open(f"{R}/urltest-period.csv")))
v15 = [int(r["gap_s"]) for r in per if r["interval_s"] == "15"]; v5 = [int(r["gap_s"]) for r in per if r["interval_s"] == "5"]
if sorted(set(v15))[-2:] != [30, 31] or st.median(v15) != 30: bad += 1; print("РАСХОЖДЕНИЕ период 15 с", st.median(v15))
has(f"при интервале 5 с от {min(v5)} до {max(v5)} с", "urltest-period.csv")
comp = collections.Counter((r["xray_server"], r["result"].startswith("available")) for r in csv.DictReader(open(f"{R}/reality-compat.csv")) if r["client"].startswith("sing-box"))
if (comp[("v26.6.27", True)], comp[("v26.9.9", False)], comp[("v26.10.31", False)]) != (3, 3, 3): bad += 1; print("РАСХОЖДЕНИЕ reality-compat", comp)
has("0 из 3 против Xray 26.9.9 и 26.10.31, 3 из 3 против 26.6.27", "reality-compat.csv")
fo = list(csv.DictReader(open(f"{R}/failover.csv")))
has(f"Таких строк {sum(r['valid'] != '1' for r in fo)} из {len(fo)}", "failover.csv")
la = [float(r["load1"]) for r in fo]; has(f"средняя нагрузка от {min(la):.0f} до {max(la):.0f}", "failover.csv")
# активное зондирование
g = collections.OrderedDict()
for r in csv.DictReader(open(f"{R}/probe.csv")):
    g.setdefault((r["target"], r["probe"]), []).append(r)
for (t, pr), v in g.items():
    res = collections.Counter(r["result"] for r in v)
    b = "/".join(map(str, sorted({int(r["bytes"]) for r in v})))
    has(f"| {t} | {pr} | {', '.join(f'{k} {n}' for k, n in sorted(res.items()))} | {b} |", "probe.csv")
# смена узла
d = list(csv.DictReader(open(f"{LAB}/../data/replace/replace.csv")))
rng = lambda k: f"{min(float(r[k]) for r in d):.1f}-{max(float(r[k]) for r in d):.1f}".replace(".", ",")
has(f"дроплет готов за {rng('created_s')} с", "replace.csv"); has(f"Reality работает через {rng('reality_ok_s')} с", "replace.csv")
has(f"Hysteria2 через {rng('hy2_ok_s')} с", "replace.csv")
# OONI
for r in csv.DictReader(open(f"{LAB}/../data/ooni/summary.csv")):
    if r["test_name"] in DOC and f"| {r['test_name']} |" in DOC:
        n = f"{int(r['ru_n']):,}".replace(",", " ")
        a, c = (x.replace(".", ",").replace("100,0", "100") for x in (r["ru_anomaly_pct"], r["de_anomaly_pct"]))
        has(f"| {r['test_name']} | {n} | {a} % | {c} % |", "ooni/summary.csv")
print(f"проверено {seen}, расхождений {bad}"); sys.exit(1 if bad else 0)
