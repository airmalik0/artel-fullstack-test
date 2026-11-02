#!/usr/bin/env python3
"""Замер сторожа объёма. Срабатывание: заморозка включается посреди потока запросов 256 КиБ, клиент на selector со сторожем.
Ложные срабатывания: сторож идёт по чистому каналу, по чистому под загрузкой и по узкому каналу.
wdtest.py --out results/watchdog.csv --reps 10 [--clean-s 1800] [--only trip|clean]"""
import argparse, csv, os, re, statistics, time
import failover as fo
HEAD = ["case", "rep", "valid", "why_invalid", "fault", "duration_s", "probes", "probe_fail", "switches", "trail", "first_switch_s",
        "first_ok_fallback_s", "fallback_path", "failed_after", "probe_med_s", "probe_max_s", "load1"]
TRIPS = {"wd_curtain_tls": ("watchdog", 5, "model_curtain", "256k", 40),
         "wd_curtain_all": ("watchdog", 5, "model_curtain_all", "256k", 60)}
LOAD = ("nohup sh -c 'while :; do curl -s -o /dev/null --socks5-hostname 127.0.0.1:10801 http://127.0.0.1:8080/16m; done' "
        ">/dev/null 2>&1 </dev/null & echo $! > /tmp/load.pid")
def wd_stats(text, t_from=0):
    """Журнал сторожа: пробы и переключения позже t_from (время ВМ)."""
    probes, sw = [], []
    for l in text.splitlines():
        p = l.split()
        if len(p) == 3 and p[1] == "switch" and float(p[0]) >= t_from:
            sw.append((float(p[0]), p[2]))
        elif len(p) == 5 and float(p[0]) >= t_from:
            probes.append((float(p[3]), p[4]))
    d = [x[0] for x in probes]
    return probes, sw, (f"{statistics.median(d):.3f}" if d else ""), (f"{max(d):.3f}" if d else "")
def trip(w, f, name, c, rep):
    r = fo.run_once(name, c, rep)
    probes, sw, med, mx = wd_stats(fo.ssh("client", "cat /tmp/wd.log"), fo.LAST["t_fault"] - fo.LAST["off"])
    w.writerow(dict(zip(HEAD, [name, rep, r["valid"], r["why_invalid"], r["fault"], c[4], len(probes), sum(p[1] == "FAIL" for p in probes),
        len(sw), ">".join(s[1] for s in sw), f"{sw[0][0] + fo.LAST['off'] - fo.LAST['t_fault']:.2f}" if sw else "",
        r["first_ok_fallback_s"], r["fallback_path"], r["failed_after"], med, mx, r["load1"]]))); f.flush()
    print(name, rep, r["valid"], r["why_invalid"], r["first_ok_fallback_s"], r["fallback_path"], len(sw), flush=True)
    return r["valid"]
def clean(w, f, name, dur, before="", after="", load=False):
    fo.reset(); fo.start_client("watchdog", 5)
    if before: fo.ssh("tspu", before)
    if load: fo.ssh("client", LOAD)
    time.sleep(dur)
    if load: fo.ssh("client", "kill $(cat /tmp/load.pid)")
    probes, sw, med, mx = wd_stats(fo.ssh("client", "cat /tmp/wd.log"))
    if after: fo.ssh("tspu", after)
    w.writerow(dict(zip(HEAD, [name, 1, 1, "", "", dur, len(probes), sum(p[1] == "FAIL" for p in probes), len(sw),
        ">".join(s[1] for s in sw), "", "", "", "", med, mx, f"{os.getloadavg()[0]:.1f}"]))); f.flush()
    print(name, len(probes), sum(p[1] == "FAIL" for p in probes), len(sw), med, mx, flush=True)
def main():
    a = argparse.ArgumentParser(); a.add_argument("--out", required=True); a.add_argument("--reps", type=int, default=10)
    a.add_argument("--clean-s", type=int, default=1800); a.add_argument("--only", default=""); a.add_argument("--append", action="store_true")
    o = a.parse_args()
    new = not (o.append and os.path.exists(o.out))
    f = open(o.out, "w" if new else "a", newline=""); w = csv.DictWriter(f, HEAD)
    if new: w.writeheader()
    fo.ssh("tspu", "sudo modprobe nfnetlink_queue; sudo /opt/lab/ctl.py net")
    if o.only != "clean":
        for name, c in TRIPS.items():
            done = tries = 0
            while done < o.reps and tries < 2 * o.reps:
                tries += 1; done += trip(w, f, name, c, tries)
    if o.only != "trip":
        NET = "sudo /opt/lab/ctl.py net"
        rate = "sudo tc qdisc replace dev lana root netem delay 20ms limit 20000 rate "
        clean(w, f, "clean", o.clean_s)
        clean(w, f, "clean_load16m", o.clean_s // 3, load=True)
        clean(w, f, "rate_1mbit", 180, rate + "1mbit", NET)
        clean(w, f, "rate_400kbit", 180, rate + "400kbit", NET)
    fo.ssh("client", "sudo /opt/lab/sbctl.sh stop")
    fo.ssh("tspu", "sudo /opt/lab/ctl.py set off; sudo nft delete table inet fault")
    fo.ssh("server", "sudo bash /tmp/provision/fo-server.sh restore")
if __name__ == "__main__":
    main()
