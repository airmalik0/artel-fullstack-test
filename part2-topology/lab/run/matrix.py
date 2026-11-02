#!/usr/bin/env python3
"""Прогон матрицы сценарий × протокол × адрес. Запускать на маке, ВМ подняты, sync.sh выполнен.
matrix.py --out results/matrix.csv --reps 7 [--scenarios a,b] [--protos a,b] [--append]"""
import argparse, csv, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); LAB = os.path.dirname(HERE)
PROTOS = "https-ok https-blocked https-wl wg awg ovpn-udp ovpn-tcp ss2022 reality reality-wl reality-mux xhttp hy2 hy2-blk hy2-obfs".split()
SCEN = "off pass sni_rst sni_drop quic_all quic_sni vpn_sig curtain_tls curtain_all fet_gfw fet_ru conn_limit wl_ip".split()
RUHOST_TOO = {"curtain_tls", "curtain_all", "wl_ip"}   # там важен второй адрес вне множества хостингов
PAR = {"off", "conn_limit"}
THR = {"off", "pass"}     # 16 МиБ качаем только там: правила модели не трогают поток после решения, а время прогона втрое меньше
RUHOST_PROTOS = {"https-ok", "wg", "awg", "ss2022", "reality", "xhttp", "hy2", "hy2-obfs"}
FIELDS = ("ts scenario proto target rep tunnel_ok tunnel_up_s http_1k ttfb_s cold_ttfb_s bytes_1m complete_1m "
          "wire_rx_1m thr_bytes thr_s thr_mbit wire_tx_bytes overhead_pct par_ok").split()

def ssh(vm, cmd, timeout=90):
    r = subprocess.run([f"{LAB}/lab.sh", "ssh", vm, cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout

def env(sc):
    return "INNER=https" if sc == "fet_ru" else ""   # S7: рисунок HTTPS внутри туннеля

def tx():
    return int(ssh("tspu", "cat /sys/class/net/lana/statistics/tx_bytes").strip())

def one(sc, p, tgt, rep):
    off = 200 if tgt == "ruhost" else 0
    row = dict.fromkeys(FIELDS, ""); row.update(ts=int(time.time()), scenario=sc, proto=p, target=tgt, rep=rep)
    ssh("tspu", "sudo /opt/lab/ctl.py reset")
    out = ssh("client", f"sudo {env(sc)} /opt/lab/rep.sh {p} {off}")
    d = {l.split(" ", 1)[0]: l.split(" ", 1)[1].split() for l in out.strip().splitlines() if " " in l}
    up = d.get("up", ["9", "0"])
    row["tunnel_ok"] = int(up[0] == "0"); row["tunnel_up_s"] = up[1]
    row["bytes_1m"] = 0; row["complete_1m"] = 0; row["http_1k"] = "000"
    if row["tunnel_ok"] and "k1" in d:
        row["http_1k"] = d["k1"][0]
        if d["k1"][0] == "200":
            row["ttfb_s"] = d["k1"][3]
            row["cold_ttfb_s"] = f"{float(up[1]) + float(d['k1'][3]):.4f}"
    if "m1" in d:
        row["bytes_1m"] = int(d["m1"][5]); row["complete_1m"] = int(int(d["m1"][5]) == 1048576)
    if "wire" in d:
        row["wire_rx_1m"] = d["wire"][0]
    if row["complete_1m"] and sc in THR:
        a = tx()
        o = ssh("client", f"sudo {env(sc)} /opt/lab/fetch.sh {p} 16m 30 {off}").split()
        b = tx()
        if len(o) == 7:
            row["thr_bytes"] = int(o[5]); row["thr_s"] = o[4]
            row["thr_mbit"] = f"{int(o[5]) * 8 / 1e6 / max(float(o[4]), 1e-6):.1f}"
            row["wire_tx_bytes"] = b - a
            if int(o[5]) == 16777216:
                row["overhead_pct"] = f"{((b - a) / 16777216 - 1) * 100:.2f}"
    if sc in PAR and row["http_1k"] == "200":
        o = ssh("client", f"sudo /opt/lab/parallel.sh {p} 20 {off}").strip()
        row["par_ok"] = o or ""
    ssh("client", f"sudo /opt/lab/proto.sh {p} down")
    return row

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--out", required=True); a.add_argument("--reps", type=int, default=7)
    a.add_argument("--scenarios", default=",".join(SCEN)); a.add_argument("--protos", default=",".join(PROTOS))
    a.add_argument("--append", action="store_true")
    x = a.parse_args()
    new = not (x.append and os.path.exists(x.out))
    f = open(x.out, "w" if new else "a", newline=""); w = csv.DictWriter(f, FIELDS)
    if new:
        w.writeheader()
    ssh("tspu", "sudo /opt/lab/ctl.py net")
    for sc in x.scenarios.split(","):
        ssh("tspu", f"sudo /opt/lab/ctl.py set {sc}")
        t0 = time.time()
        for p in x.protos.split(","):
            for tgt in (["foreign", "ruhost"] if sc in RUHOST_TOO and p in RUHOST_PROTOS else ["foreign"]):
                for r in range(1, x.reps + 1):
                    try:
                        w.writerow(one(sc, p, tgt, r))
                    except subprocess.TimeoutExpired:
                        w.writerow(dict.fromkeys(FIELDS, "") | dict(ts=int(time.time()), scenario=sc, proto=p, target=tgt, rep=r, tunnel_ok="timeout"))
                    f.flush()
        print(f"{sc} done {time.time() - t0:.0f}s", flush=True)
    ssh("tspu", "sudo /opt/lab/ctl.py set off")

if __name__ == "__main__":
    sys.exit(main())
