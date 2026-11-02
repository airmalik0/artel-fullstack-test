#!/usr/bin/env python3
"""Прозрачный локальный прокси между Claude Code и DeepSeek.

Показывает, что реально уходит на провайдера: модель, thinking, effort,
число инструментов, заголовки beta. Заголовки авторизации в журнал не пишутся.

  tools/wire-tap.py 9099 /tmp/wire.jsonl [/tmp/wire-dump]
  ANTHROPIC_BASE_URL=http://127.0.0.1:9099 ...

Третий аргумент: каталог, куда сложить тело каждого запроса целиком, чтобы
прочитать системный промпт глазами. Держать вне архива и evidence.
"""
import hashlib
import http.client
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "api.deepseek.com"
PREFIX = "/anthropic"
DROP_REQ = {"host", "content-length", "accept-encoding", "connection"}
DROP_RESP = {"transfer-encoding", "connection", "content-length"}

port = int(sys.argv[1])
log_path = sys.argv[2]
dump_dir = sys.argv[3] if len(sys.argv) > 3 else None
if dump_dir:
    os.makedirs(dump_dir, mode=0o700, exist_ok=True)


def summarize(path, headers, body):
    rec = {
        "ts": time.strftime("%H:%M:%S"),
        "path": path,
        "ua": headers.get("user-agent", ""),
        "beta": headers.get("anthropic-beta", ""),
        "x_app": headers.get("x-app", ""),
    }
    try:
        data = json.loads(body)
    except ValueError:
        rec["unparsed_bytes"] = len(body)
        return rec, None
    system = data.get("system") or ""
    system_text = system if isinstance(system, str) else json.dumps(system, ensure_ascii=False)
    tools = data.get("tools") or []
    rec.update(
        {
            "model": data.get("model"),
            "max_tokens": data.get("max_tokens"),
            "stream": data.get("stream"),
            "thinking": data.get("thinking"),
            "output_config": data.get("output_config"),
            "context_management": bool(data.get("context_management")),
            "tools": len(tools),
            "tool_names": [t.get("name") for t in tools][:40],
            "messages": len(data.get("messages") or []),
            "system_chars": len(system_text),
            "system_sha": hashlib.sha256(system_text.encode()).hexdigest()[:12],
            "body_keys": sorted(data.keys()),
        }
    )
    return rec, data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _relay(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        rec, data = summarize(self.path, self.headers, body)
        if dump_dir and data is not None:
            name = f"{time.time():.3f}.json"
            with open(os.path.join(dump_dir, name), "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False)
            os.chmod(os.path.join(dump_dir, name), 0o600)

        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP_REQ}
        conn = http.client.HTTPSConnection(UPSTREAM, 443, timeout=600)
        conn.request(self.command, PREFIX + self.path, body or None, headers)
        resp = conn.getresponse()
        rec["status"] = resp.status
        rec["resp_ctype"] = resp.getheader("content-type", "")
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")

        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() not in DROP_RESP:
                self.send_header(key, value)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.close_connection = True
        conn.close()

    do_POST = _relay
    do_GET = _relay
    do_HEAD = _relay


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
