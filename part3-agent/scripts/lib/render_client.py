#!/usr/bin/env python3
"""Пишет клиентские конфиги из параметров узла. Читает JSON из stdin, ничего не печатает."""
import json
import os
import sys
import urllib.parse

out_dir, host, sni = sys.argv[1:4]
p = json.load(sys.stdin)
os.makedirs(out_dir, mode=0o700, exist_ok=True)


def write(name, text):
    path = os.path.join(out_dir, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)


xray = {
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}}],
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": host, "port": 443, "users": [
            {"id": p["uuid"], "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
            "serverName": sni, "fingerprint": "chrome",
            "publicKey": p["public_key"], "shortId": p["short_id"]}},
    }],
}
write("xray-client.json", json.dumps(xray, indent=2) + "\n")

write("hysteria-client.yaml", f"""server: {host}:443
auth: {p['password']}
tls:
  sni: {sni}
  insecure: true
  pinSHA256: {p['pin']}
socks5:
  listen: 127.0.0.1:10809
""")

query = urllib.parse.urlencode({
    "encryption": "none", "security": "reality", "type": "tcp", "flow": "xtls-rprx-vision",
    "sni": sni, "fp": "chrome", "pbk": p["public_key"], "sid": p["short_id"]})
pin = urllib.parse.quote(p["pin"])
write("links.txt", f"vless://{p['uuid']}@{host}:443?{query}#reality-{host}\n"
                   f"hysteria2://{p['password']}@{host}:443/?sni={sni}&insecure=1&pinSHA256={pin}#hy2-{host}\n")
