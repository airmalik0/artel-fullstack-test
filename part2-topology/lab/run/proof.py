#!/usr/bin/env python3
"""Обязательная проба стенда: модель выключена, значит заведомо запрещённое проходит;
модель включена, значит оно режется. Без этого матрица ничего не значит. proof.py <out.csv> [повторов]"""
import csv, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import matrix as m
PAIRS = [("sni_rst", "https-blocked"), ("sni_drop", "https-blocked"), ("quic_all", "hy2"), ("quic_sni", "hy2-blk"),
         ("vpn_sig", "wg"), ("vpn_sig", "ovpn-udp"), ("vpn_sig", "ovpn-tcp"), ("curtain_tls", "https-ok"),
         ("curtain_all", "https-ok"), ("fet_gfw", "ss2022"), ("fet_ru", "ss2022"), ("conn_limit", "https-ok"), ("wl_ip", "https-ok")]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 5
w = csv.writer(open(sys.argv[1], "w", newline="")); w.writerow(["scenario", "proto", "model", "reps", "complete_1m", "par_ok", "verdict"])
m.ssh("tspu", "sudo /opt/lab/ctl.py net"); bad = 0
for sc, p in PAIRS:
    res = {}
    for mode, name in (("off", sc), ("on", sc)):
        target = "off" if mode == "off" else sc
        m.ssh("tspu", f"sudo /opt/lab/ctl.py set {target}")
        m.PAR.add(target)
        rows = [m.one(target if mode == "on" else "off", p, "foreign", r) for r in range(N)]
        ok = sum(r["complete_1m"] for r in rows)
        par = [r["par_ok"] for r in rows]
        res[mode] = ok, par
        passed = ok == N if mode == "off" else (ok == 0 or (sc == "conn_limit" and all(str(x) in ("0", "") for x in par)))
        bad += not passed
        w.writerow([sc, p, mode, N, ok, "/".join(map(str, par)) if sc == "conn_limit" else "", "ok" if passed else "FAIL"])
    print(sc, p, res, flush=True)
print("FAILED" if bad else "ALL OK", bad)
m.ssh("tspu", "sudo /opt/lab/ctl.py set off")
