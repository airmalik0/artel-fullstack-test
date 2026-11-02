#!/usr/bin/env python3
"""Сводит results.jsonl и захват tcpdump с дроплета. analyze.py <raw_dir>
tcp_flows.csv: по каждому TCP-соединению от узла check-host: сколько байт сервер отправил,
сколько подтвердил клиент, кто закрыл. Захват читается как текст: tcpdump -nn -tt -S -r."""
import collections, csv, json, re, subprocess, sys
RAW = sys.argv[1]; ME = sys.argv[2] if len(sys.argv) > 2 else "198.51.100.7"
NODE = {"185.130.104.238": "ru1", "194.26.229.20": "ru2", "185.37.147.117": "de4", "185.209.161.145": "nl1", "38.145.202.12": "us1"}
rows = []
for l in open(f"{RAW}/results.jsonl"):
    d = json.loads(l)
    for n, v in (d.get("result") or {}).items():
        rows.append([d["round"], d["type"], d["host"], n.split(".")[0], json.dumps(v)[:200]])
with open(f"{RAW}/results.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow("round type host node raw".split()); w.writerows(rows)
fl = collections.OrderedDict()
pat = re.compile(r"^(\S+) IP (\S+)\.(\d+) > (\S+)\.(\d+): Flags \[([^\]]*)\](?:, seq (\d+)(?::(\d+))?)?(?:, ack (\d+))?.*length (\d+)")
for line in open(sys.argv[3] if len(sys.argv) > 3 else f"{RAW}/cap.txt", errors="replace"):
    m = pat.match(line)
    if not m:
        continue
    t, a, ap, b, bp, fg, s1, s2, ack, ln = m.groups(); ln = int(ln)
    if b == ME and a in NODE and bp in ("80", "443"):
        k = (a, ap, bp)
        e = fl.setdefault(k, dict(t0=float(t), s0=None, srv_end=0, ackmax=0, cli_rst=0, cli_fin=0, srv_fin=0, srv_rst=0, retrans=0, last=0, seen=set()))
        if "S" in fg:
            continue
        if ack and e["s0"] is not None:
            e["ackmax"] = max(e["ackmax"], int(ack) - e["s0"])
        e["cli_rst"] += "R" in fg; e["cli_fin"] += "F" in fg; e["last"] = float(t)
    elif a == ME and b in NODE and ap in ("80", "443"):
        k = (b, bp, ap)
        e = fl.get(k)
        if e is None:
            continue
        if "S" in fg and s1:
            e["s0"] = int(s1) + 1
        elif s1 and e["s0"] is not None and ln:
            end = int(s2) - e["s0"]
            if end <= e["srv_end"]:
                e["retrans"] += 1
            e["srv_end"] = max(e["srv_end"], end)
        e["srv_fin"] += "F" in fg; e["srv_rst"] += "R" in fg
with open(f"{RAW}/tcp_flows.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow("node dst_port t0 dur_s server_sent_bytes client_acked_bytes retrans_segments client_fin client_rst server_fin server_rst".split())
    for k, e in fl.items():
        w.writerow([NODE[k[0]], k[2], f"{e['t0']:.0f}", f"{e['last'] - e['t0']:.2f}", e["srv_end"], e["ackmax"], e["retrans"], e["cli_fin"], e["cli_rst"], e["srv_fin"], e["srv_rst"]])
print("flows", len(fl))
