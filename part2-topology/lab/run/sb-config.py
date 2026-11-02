#!/usr/bin/env python3
"""Клиентский sing-box с группой urltest: Reality и Hysteria2 на первом выходе, Hysteria2 с salamander на втором.
sb-config.py <url_пробы> <интервал> [selector]  -> /tmp/sb.json. selector: ручной выбор через Clash API."""
import json, re, sys
url, interval = sys.argv[1], sys.argv[2]; sel = len(sys.argv) > 3
x = json.load(open("/etc/lab/xray-reality.json"))["outbounds"][0]
u = x["settings"]["vnext"][0]["users"][0]; r = x["streamSettings"]["realitySettings"]
hy = open("/etc/lab/hy-plain.yaml").read(); ob = open("/etc/lab/hy-obfs.yaml").read()
pw = re.search(r"auth: (\S+)", hy).group(1); salam = re.search(r"password: ([0-9a-f]+)", ob).group(1)
tls = {"enabled": True, "server_name": "other.example", "insecure": True}
out = [
 {"type": "vless", "tag": "reality", "server": "10.10.2.11", "server_port": 443, "uuid": u["id"], "flow": "xtls-rprx-vision",
  "tls": {"enabled": True, "server_name": "other.example", "utls": {"enabled": True, "fingerprint": "chrome"},
          "reality": {"enabled": True, "public_key": r["publicKey"], "short_id": r["shortId"]}}},
 {"type": "hysteria2", "tag": "hy2", "server": "10.10.2.11", "server_port": 443, "password": pw, "tls": tls},
 {"type": "hysteria2", "tag": "exit2", "server": "10.10.2.18", "server_port": 443, "password": pw, "tls": tls,
  "obfs": {"type": "salamander", "password": salam}},
]
names = ["reality", "hy2", "exit2"]
if sel:
    out.append({"type": "selector", "tag": "auto", "outbounds": names, "default": "reality", "interrupt_exist_connections": True})
else:
    out.append({"type": "urltest", "tag": "auto", "outbounds": names, "url": url, "interval": interval, "tolerance": 300,
                "interrupt_exist_connections": True})
cfg = {"log": {"level": "warn"}, "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10801}],
       "outbounds": out, "route": {"final": "auto"}}
if sel:
    cfg["experimental"] = {"clash_api": {"external_controller": "127.0.0.1:9090"}}
json.dump(cfg, open("/tmp/sb.json", "w"), indent=1)
