#!/usr/bin/env python3
"""Замер переключения клиента. Запуск на маке. Простой считается по самому клиенту:
от последнего успешного запроса перед отказом до первого успешного после него.
failover.py <out.csv> <повторов>"""
import csv, subprocess, sys, time, os
LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def ssh(vm, cmd, t=120):
    return subprocess.run([f"{LAB}/lab.sh", "ssh", vm, cmd], capture_output=True, text=True, timeout=t).stdout
FAULT = {"tcp443": "nft add rule inet fault fw ip daddr 10.10.2.11 tcp dport 443 drop",
         "ip": "nft add rule inet fault fw ip daddr 10.10.2.11 drop",
         "curtain": "nft add rule inet fault fw ip saddr 10.10.2.11 tcp sport 443 ct reply bytes '>' 16384 drop"}
CASES = [  # имя, отказ, объект пробы, байт, url для urltest, сторож
    ("tcp443_urltest15", "tcp443", "1k", 1024, False),
    ("ip_urltest15", "ip", "1k", 1024, False),
    ("curtain_urltest15", "curtain", "256k", 262144, False),
    ("curtain_watchdog5", "curtain", "256k", 262144, True),
    ("ip_watchdog5", "ip", "1k", 1024, True),
]
SETUP = "sudo nft delete table inet fault 2>/dev/null; sudo nft add table inet fault; sudo nft add chain inet fault fw '{ type filter hook forward priority 0; policy accept; }'; sudo conntrack -F 2>/dev/null"
f = open(sys.argv[1], "w", newline=""); w = csv.writer(f)
w.writerow(["case", "rep", "gap_s", "failed_requests", "recovered", "selected_after"])
ssh("tspu", "sudo /opt/lab/ctl.py net; sudo /opt/lab/ctl.py set off")
for name, fault, obj, size, wd in CASES:
    for rep in range(1, int(sys.argv[2]) + 1):
        ssh("tspu", SETUP)
        ssh("client", "sudo /opt/lab/proto.sh x down; pids=$(pgrep -x sing-box | tr '\\n' ' '); [ -n \"$pids\" ] && sudo kill -9 $pids; "
                      "pids=$(pgrep -f watchdog.py | tr '\\n' ' '); [ -n \"$pids\" ] && sudo kill -9 $pids; "
                      f"python3 /opt/lab/sb-config.py http://127.0.0.1:8080/1k 15s {'selector' if wd else ''}; "
                      "nohup sing-box run -c /tmp/sb.json >/tmp/sb.log 2>&1 & "
                      + (f"sleep 1; nohup python3 /opt/lab/watchdog.py 5 {'256k' if obj == '256k' else '1k'} >/tmp/wd.log 2>&1 &" if wd else ""))
        time.sleep(4)
        p = subprocess.Popen([f"{LAB}/lab.sh", "ssh", "client", f"/opt/lab/probeloop.sh 48 {obj} {size}"], stdout=subprocess.PIPE, text=True)
        time.sleep(8)
        ssh("tspu", "sudo " + FAULT[fault])
        o = p.communicate()[0].strip().splitlines()
        rows = [(float(a), int(b)) for a, b in (l.split() for l in o)]
        fail = [i for i, r in enumerate(rows) if r[1] == 0]
        if not fail:
            w.writerow([name, rep, 0, 0, "no_failure_seen", ""]); f.flush(); continue
        i0 = fail[0]; last_ok = rows[i0 - 1][0] if i0 else rows[0][0]
        rec = next((rows[i][0] for i in range(i0, len(rows)) if rows[i][1] == 1), None)
        sel = ssh("client", "tail -1 /tmp/sb.log | cut -c1-60")
        w.writerow([name, rep, f"{rec - last_ok:.2f}" if rec else "", len(fail), int(rec is not None), ""]); f.flush()
        print(name, rep, f"{rec - last_ok:.2f}" if rec else "no recovery in window", flush=True)
ssh("client", "pids=$(pgrep -x sing-box | tr '\\n' ' '); [ -n \"$pids\" ] && sudo kill -9 $pids; pids=$(pgrep -f watchdog.py | tr '\\n' ' '); [ -n \"$pids\" ] && sudo kill -9 $pids")
ssh("tspu", "sudo nft delete table inet fault")
