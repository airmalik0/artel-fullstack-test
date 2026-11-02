#!/usr/bin/env python3
"""Клиентский sing-box: Reality на выходе A, Hysteria2 с Salamander на A и на B, порядок как пути 1, 2, 3.
sb-config.py urltest <интервал> <tolerance> <url> | selector  -> /tmp/sb.json, /tmp/xr1.json, /tmp/xr4.json.
Clash API 127.0.0.1:9090 в обоих режимах.
Reality идёт через локальный Xray по SOCKS: sing-box 1.14.4 вырезает X25519MLKEM768 из ClientHello,
а Xray с 26.9.9 такой ClientHello отвергает (results/reality-compat.csv). Группа и переключение остаются в sing-box.
SNI Reality взят из блоклиста модели: так сценарий sni_drop режет ровно основной транспорт и не задевает запасной."""
import json, re, sys
def xray(port, host, sni, path):
    c = json.load(open("/etc/lab/xray-reality.json")); o = c["outbounds"][0]
    c["inbounds"][0]["port"] = port; o["settings"]["vnext"][0]["address"] = host
    o["streamSettings"]["realitySettings"]["serverName"] = sni
    json.dump(c, open(path, "w"))
xray(10811, "10.10.2.11", "blocked.example", "/tmp/xr1.json")
xray(10812, "10.10.2.211", "allowed.example", "/tmp/xr4.json")
pw = re.search(r"auth: (\S+)", open("/etc/lab/hy-plain.yaml").read()).group(1)
salam = re.search(r"password: ([0-9a-f]+)", open("/etc/lab/hy-obfs.yaml").read()).group(1)
def hy(tag, addr):
    return {"type": "hysteria2", "tag": tag, "server": addr, "server_port": 443, "password": pw,
            "tls": {"enabled": True, "server_name": "other.example", "insecure": True},
            "obfs": {"type": "salamander", "password": salam}}
def socks(tag, port):
    return {"type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": port, "version": "5"}
out = [socks("reality", 10811), hy("hy2s", "10.10.2.11"), hy("exit2", "10.10.2.18")]
names = ["reality", "hy2s", "exit2"]
if sys.argv[1] == "urltest":
    out.append({"type": "urltest", "tag": "auto", "outbounds": names, "interval": sys.argv[2], "tolerance": int(sys.argv[3]),
                "url": sys.argv[4], "interrupt_exist_connections": True})
else:
    # Путь 4 стенда: адрес вне множества «хостинг» и SNI из белого списка. Настоящего входа в РФ на стенде нет.
    out.append(socks("entry4", 10812))
    out.append({"type": "selector", "tag": "auto", "outbounds": names + ["entry4"], "default": "reality", "interrupt_exist_connections": True})
json.dump({"log": {"level": "debug", "timestamp": True, "output": "/tmp/sb.log"},
           "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10801}],
           "outbounds": out, "route": {"final": "auto"},
           "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}, open("/tmp/sb.json", "w"), indent=1)
