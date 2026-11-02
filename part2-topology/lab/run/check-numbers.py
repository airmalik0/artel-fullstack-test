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
# сторож и разделы 5, 8.3, 9
cf = lambda v: f"{st.median(v):.1f} [{min(v):.1f}..{max(v):.1f}]".replace(".", ",").replace(",,", "..")
wd = list(csv.DictReader(open(f"{R}/watchdog.csv")))
val = lambda rows, k, f: [float(r[f]) for r in rows if r["case"] == k and r.get("valid") == "1" and r[f] != ""]
for k, f, where in (("urltest15_ip_ban", fo, "`urltest` 15 с: "), ("urltest15_model_sni", fo, "`urltest` 15 с: "), ("urltest15_service_stop", fo, "`urltest` 15 с: "),
                    ("watchdog5_ip_ban", fo, "сторож "), ("watchdog5_model_sni", fo, "сторож "), ("watchdog5_service_stop", fo, "сторож ")):
    has(where + cf(val(f, k, "first_ok_fallback_s")) + " с", "failover.csv")
has("через " + cf(val(wd, "wd_curtain_tls", "first_ok_fallback_s")) + " с", "watchdog.csv")
has("с пределом докачки 30 с " + cf(val(wd, "limit30_curtain_tls", "first_ok_fallback_s")) + " с", "watchdog.csv")
has(cf(val(wd, "wd_curtain_all", "first_ok_fallback_s")) + " с", "watchdog.csv")
row = {r["case"]: r for r in wd}
for k, t in (("clean", "0 из {p} за 30 минут"), ("clean_load16m", "под постоянной загрузкой 0 из {p}"), ("rate_1mbit", "на 1 Мбит/с 0 из {p}"), ("limit30_rate_400kbit", "На 400 кбит/с 0 из {p}")):
    if row[k]["switches"] != "0": bad += 1; print("РАСХОЖДЕНИЕ ложные", k)
    has(t.format(p=row[k]["probes"]), "watchdog.csv")
has(f"{row['rate_400kbit']['probes']} проб, {row['rate_400kbit']['switches']} ложных переключений", "watchdog.csv")
med = lambda k: st.median(val(wd, k, "first_ok_fallback_s"))
has(f"Цена около {med('limit30_curtain_tls') - med('wd_curtain_tls'):.0f} с на «занавесе»", "watchdog.csv")
cur = [r for r in fo if r["case"] == "urltest15_model_curtain" and r["valid"] == "1"]
if any(r["first_ok_fallback_s"] for r in cur) or len(cur) != 10: bad += 1; print("РАСХОЖДЕНИЕ urltest на занавесе")
ru = collections.Counter((r["proto"], r["target"]) for r in csv.DictReader(open(f"{R}/ruhost-hy2.csv")) if r["complete_1m"] == "1")
has(f"на этом адресе {ru[('hy2', 'ruhost')]} из 20, на обычном адресе {ru[('hy2', 'foreign')]} из 5, у `hy2-obfs` вне хостинга {ru[('hy2-obfs', 'ruhost')]} из 20", "ruhost-hy2.csv")
t = {l.split()[0]: int(l.split("s=")[1]) for l in open(f"{R}/rebuild.times") if " rc=" in l}
has(f"на новых дисках после всех правок: {sum(t.values())} с, из них подъём ВМ {t['up']} с, установка {t['provision']} с, конфиги {t['syncgen']} с, проба {t['proof']} с", "rebuild.times")
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
