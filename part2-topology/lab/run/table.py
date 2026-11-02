#!/usr/bin/env python3
"""Таблицы для TOPOLOGY.md из results/matrix.csv. table.py results/matrix.csv"""
import collections, csv, statistics as st, sys
rows = list(csv.DictReader(open(sys.argv[1])))
SC = "off pass sni_rst sni_drop quic_all quic_sni vpn_sig curtain_tls curtain_all fet_gfw fet_ru conn_limit wl_ip".split()
PR = "https-ok https-blocked https-wl wg awg ovpn-udp ovpn-tcp ss2022 reality reality-wl reality-mux xhttp hy2 hy2-blk hy2-obfs".split()
g = collections.defaultdict(list)
for r in rows:
    g[(r["scenario"], r["proto"], r["target"])].append(r)
def cell(v):
    if not v:
        return "-"
    n = len(v); ok = sum(r["complete_1m"] == "1" for r in v); k = sum(r["http_1k"] == "200" for r in v)
    return f"{ok}/{n}" if ok == n or k == 0 or ok > 0 else f"0/{n}*"
print("Успешная загрузка 1 МиБ, успехов из повторов. Звёздочка: 1 КиБ проходит, а 1 МиБ нет, то есть заморозка на объёме.\n")
print("| сценарий | " + " | ".join(PR) + " |\n|" + "---|" * (len(PR) + 1))
for t in ("foreign", "ruhost"):
    for s in SC:
        if not any(g.get((s, p, t)) for p in PR):
            continue
        name = s if t == "foreign" else s + " (адрес вне хостинга)"
        print(f"| {name} | " + " | ".join(cell(g.get((s, p, t))) for p in PR) + " |")
med = lambda v, f: (lambda x: f"{f.format(st.median(x))} [{f.format(min(x))}..{f.format(max(x))}]" if x else "-")([float(i) for i in v if i])
print("\nКонтроль, модель выключена. Медиана [мин..макс].\n")
print("| протокол | n | первый байт с холодного старта, с | 16 МиБ, Мбит/с | накладные, % |\n|---|---|---|---|---|")
for p in PR:
    v = g.get(("off", p, "foreign"), [])
    print(f"| {p} | {len(v)} | {med([r['cold_ttfb_s'] for r in v], '{:.3f}')} | {med([r['thr_mbit'] for r in v], '{:.1f}')} | {med([r['overhead_pct'] for r in v], '{:.2f}')} |")
print("\nЦена модели, сценарий pass.\n")
print("| протокол | n | первый байт, с | 16 МиБ, Мбит/с |\n|---|---|---|---|")
for p in PR:
    v = g.get(("pass", p, "foreign"), [])
    print(f"| {p} | {len(v)} | {med([r['cold_ttfb_s'] for r in v], '{:.3f}')} | {med([r['thr_mbit'] for r in v], '{:.1f}')} |")
print("\nБайт до остановки на проводе (wire_rx_1m) и полезной нагрузки (bytes_1m), заморозка. Медиана [мин..макс].\n")
print("| сценарий | протокол | n | на проводе | полезная нагрузка |\n|---|---|---|---|---|")
for s in ("curtain_tls", "curtain_all"):
    for p in PR:
        v = [r for r in g.get((s, p, "foreign"), []) if r["complete_1m"] == "0" and r["http_1k"] == "200"]
        if v:
            print(f"| {s} | {p} | {len(v)} | {med([r['wire_rx_1m'] for r in v], '{:.0f}')} | {med([r['bytes_1m'] for r in v], '{:.0f}')} |")
print("\nconn_limit: завершилось из 20 одновременных. Медиана [мин..макс].\n")
print("| протокол | off | conn_limit |\n|---|---|---|")
for p in PR:
    a = g.get(("off", p, "foreign"), []); b = g.get(("conn_limit", p, "foreign"), [])
    print(f"| {p} | {med([r['par_ok'] for r in a], '{:.0f}')} | {med([r['par_ok'] for r in b], '{:.0f}')} |")
