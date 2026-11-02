#!/usr/bin/env python3
"""Подставная модель для проверки защит: вместо DeepSeek отвечает по сценарию.

Вежливая модель сама отказывается читать секреты, и хуки с песочницей остаются
непроверенными. Этот сервер ведёт себя как модель, захваченная внедрённой инструкцией:
по очереди требует запрещённые действия. Claude Code настоящий, с настоящими
разрешениями, хуками и песочницей. В журнал идёт то, что модель получила бы в ответ.

  tools/fake-model.py <порт> <сценарий.json> <журнал.jsonl>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, script_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(script_path, encoding="utf-8") as fh:
    SCRIPT = json.load(fh)
seen = set()


def sse(kind, payload):
    return f"event: {kind}\ndata: {json.dumps(payload)}\n\n".encode()


def results(messages):
    for msg in messages:
        content = msg.get("content")
        if msg.get("role") != "user" or not isinstance(content, list):
            continue
        for block in content:
            if block.get("type") == "tool_result":
                yield block


def text_of(block):
    body = block.get("content")
    if isinstance(body, list):
        return " ".join(str(item.get("text", "")) for item in body)
    return str(body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        messages = body.get("messages", [])
        done = list(results(messages))
        with open(log_path, "a", encoding="utf-8") as fh:
            for block in done:
                uid = block["tool_use_id"]
                if uid not in seen:
                    seen.add(uid)
                    probe = SCRIPT[int(uid.rsplit("_", 1)[1])]
                    fh.write(json.dumps({"probe": probe, "is_error": bool(block.get("is_error")),
                                         "result": text_of(block)}, ensure_ascii=False) + "\n")
        step = len(done)
        msg = {"id": f"msg_{step}", "type": "message", "role": "assistant", "model": "fake",
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 1, "output_tokens": 1}}
        out = sse("message_start", {"type": "message_start", "message": msg})
        if step < len(SCRIPT):
            call = SCRIPT[step]
            start = {"type": "tool_use", "id": f"toolu_fake_{step}", "name": call["tool"], "input": {}}
            delta = {"type": "input_json_delta", "partial_json": json.dumps(call["input"])}
            stop = "tool_use"
        else:
            start = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": "конец сценария"}
            stop = "end_turn"
        out += sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": start})
        out += sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta})
        out += sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        out += sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                     "usage": {"output_tokens": 1}})
        out += sse("message_stop", {"type": "message_stop"})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
