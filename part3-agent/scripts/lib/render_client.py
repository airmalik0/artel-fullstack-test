#!/usr/bin/env python3
"""Пишет клиентские конфиги из параметров узла. Читает JSON из stdin, ничего не печатает."""
import json
import os
import sys
import urllib.parse

out_dir, host, sni, extra, alt_port = sys.argv[1:6]
alt_port = int(alt_port)
# Второй Reality идёт с другим именем из serverNames: так проверка заодно доказывает, что список работает.
alt_sni = extra.split(",")[0]
p = json.load(sys.stdin)
os.makedirs(out_dir, mode=0o700, exist_ok=True)


def write(name, text):
    path = os.path.join(out_dir, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)


def socks(tag, port):
    return {"tag": tag, "listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"udp": True}}


def reality(tag, port, name):
    return {
        "tag": tag, "protocol": "vless",
        "settings": {"vnext": [{"address": host, "port": port, "users": [
            {"id": p["uuid"], "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
            "serverName": name, "fingerprint": "chrome",
            "publicKey": p["public_key"], "shortId": p["short_id"]}},
    }


# Каждому транспорту свой локальный SOCKS: 10808 Reality на 443, 10810 второй Reality.
xray = {
    "log": {"loglevel": "warning"},
    "inbounds": [socks("socks-main", 10808), socks("socks-alt", 10810)],
    "outbounds": [reality("reality", 443, sni), reality("reality-alt", alt_port, alt_sni)],
    "routing": {"rules": [
        {"type": "field", "inboundTag": ["socks-main"], "outboundTag": "reality"},
        {"type": "field", "inboundTag": ["socks-alt"], "outboundTag": "reality-alt"}]},
}
write("xray-client.json", json.dumps(xray, indent=2) + "\n")

write("hysteria-client.yaml", f"""server: {host}:443
auth: {p['password']}
obfs:
  type: salamander
  salamander:
    password: {p['obfs_password']}
tls:
  sni: {sni}
  insecure: true
  pinSHA256: {p['pin']}
socks5:
  listen: 127.0.0.1:10809
""")

def vless(port, name, label):
    query = urllib.parse.urlencode({
        "encryption": "none", "security": "reality", "type": "tcp", "flow": "xtls-rprx-vision",
        "sni": name, "fp": "chrome", "pbk": p["public_key"], "sid": p["short_id"]})
    return f"vless://{p['uuid']}@{host}:{port}?{query}#{label}-{host}\n"


hy2 = urllib.parse.urlencode({
    "sni": sni, "obfs": "salamander", "obfs-password": p["obfs_password"],
    "insecure": 1, "pinSHA256": p["pin"]})
write("links.txt", vless(443, sni, "reality") + vless(alt_port, alt_sni, "reality-alt")
      + f"hysteria2://{p['password']}@{host}:443/?{hy2}#hy2-{host}\n")
