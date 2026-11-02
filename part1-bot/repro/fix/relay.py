#!/usr/bin/env python3
"""Реле для контейнера без сети. Только стандартная библиотека.

  relay.py in --listen 127.0.0.1:18190 --link /run/botfix/bot/link.sock
      Внутри контейнера, под супервизором. HTTP CONNECT для бота.
      Если внешней стороны нет, сразу отвечает 503.
  relay.py attach --link /run/botfix/bot/link.sock
      Внутри контейнера, запускается снаружи через ssh или docker exec -i.
      Соединяет свой stdin/stdout с сокетом link.
  relay.py out --allow api.telegram.org:443 --journal FILE -- КОМАНДА...
      Снаружи, на машине с сетью. КОМАНДА запускает attach. Белый список,
      переподключение, журнал без содержимого.

TLS идёт от бота до Telegram, реле видит только шифрованные байты.
Белый список стоит снаружи: взломанный контейнер не может его поменять.
"""
import argparse
import asyncio
import os
import re
import socket
import struct
import sys
import threading
import time

OPEN, OPENED, DATA, CLOSE = 1, 2, 3, 4
HDR = struct.Struct("!IBI")
CHUNK = 65536
MAX_FRAME = 1 << 20
CONNECT_TIMEOUT = 15
MAX_TARGET = 261  # 255 на имя, двоеточие, 5 на порт
UNSAFE = re.compile(r"[^A-Za-z0-9.:-]")


def log(journal, msg):
    line = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + msg + "\n"
    journal.write(line)
    journal.flush()


async def read_frame(r):
    sid, kind, n = HDR.unpack(await r.readexactly(HDR.size))
    if n > MAX_FRAME:
        raise ConnectionError("frame too large")
    return sid, kind, await r.readexactly(n) if n else b""


def send_frame(w, sid, kind, data=b""):
    w.write(HDR.pack(sid, kind, len(data)) + data)


class Inner:
    """Сторона контейнера: CONNECT от бота в кадры по link."""

    def __init__(self, journal):
        self.journal = journal
        self.link = None
        self.streams = {}
        self.sid = 0

    def drop_streams(self):
        for w, opened in self.streams.values():
            if not opened.done():
                opened.set_result(b"503 relay link down")
            w.close()
        self.streams.clear()

    async def on_link(self, r, w):
        if self.link:
            self.link.close()  # новая сессия вытесняет зависшую старую
        self.drop_streams()
        self.link = w
        log(self.journal, "link up")
        try:
            while True:
                sid, kind, data = await read_frame(r)
                stream = self.streams.get(sid)
                if stream is None:
                    continue
                client, opened = stream
                if kind == OPENED and not opened.done():
                    opened.set_result(data)
                elif kind == DATA:
                    client.write(data)
                    try:
                        await client.drain()
                    except (ConnectionError, OSError):
                        client.close()  # умер один клиент, линия живёт
                elif kind == CLOSE:
                    client.close()
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            w.close()
            if self.link is w:
                self.link = None
                self.drop_streams()
                log(self.journal, "link down")

    async def on_client(self, r, w):
        self.sid += 1
        sid = self.sid
        link = self.link
        try:
            head = (await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 10)).split(b" ")
            if head[0] != b"CONNECT" or len(head) < 3:
                return await self.refuse(w, b"405 only CONNECT")
            if link is None:
                return await self.refuse(w, b"503 relay link down")
            opened = asyncio.get_running_loop().create_future()
            self.streams[sid] = (w, opened)
            send_frame(link, sid, OPEN, head[1])
            status = await asyncio.wait_for(opened, CONNECT_TIMEOUT + 5)
            if status:
                return await self.refuse(w, status)
            w.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await w.drain()
            while chunk := await r.read(CHUNK):
                send_frame(link, sid, DATA, chunk)
                await link.drain()
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            w.close()
            if self.streams.pop(sid, None) and self.link is link and link is not None:
                send_frame(link, sid, CLOSE)

    @staticmethod
    async def refuse(w, status):
        w.write(b"HTTP/1.1 " + status + b"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        await w.drain()


async def run_in(args):
    inner = Inner(sys.stdout)
    host, port = args.listen.rsplit(":", 1)
    await asyncio.start_unix_server(inner.on_link, args.link)
    server = await asyncio.start_server(inner.on_client, host, int(port))
    log(inner.journal, f"listen {args.listen}")
    await server.serve_forever()


def run_attach(args):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(args.link)
    out = sys.stdout.buffer

    def pump_to_stdout():
        try:
            while data := sock.recv(CHUNK):
                out.write(data)
                out.flush()
        finally:  # вход реле закрыл линию: выхожу, иначе внешняя сторона считает её живой и не переподключается
            os._exit(0)

    threading.Thread(target=pump_to_stdout, daemon=True).start()
    while data := sys.stdin.buffer.read1(CHUNK):
        sock.sendall(data)


class Outer:
    """Внешняя сторона: кадры из link в TCP, только по белому списку."""

    def __init__(self, allow, journal):
        self.allow = allow
        self.journal = journal
        self.streams = {}
        self.drain_lock = None

    async def open_stream(self, link, sid, target):
        host, port = target.rsplit(":", 1)
        try:
            # Один недоступный адрес не должен стоить запроса: адреса пробуются внахлёст.
            r, w = await asyncio.wait_for(
                asyncio.open_connection(host, int(port), happy_eyeballs_delay=0.25), CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError) as e:
            log(self.journal, f"fail sid={sid} {target} {type(e).__name__}")
            send_frame(link, sid, OPENED, b"502 upstream connect failed")
            return
        stream = {"w": w, "up": 0, "down": 0, "t": time.monotonic(), "target": target}
        self.streams[sid] = stream
        log(self.journal, f"open sid={sid} {target}")
        send_frame(link, sid, OPENED)
        try:
            while chunk := await r.read(CHUNK):
                stream["down"] += len(chunk)
                send_frame(link, sid, DATA, chunk)
                async with self.drain_lock:  # до Python 3.11 два drain разом падают
                    await link.drain()
        except (ConnectionError, OSError):
            pass
        self.close_stream(sid)
        if not link.is_closing():
            send_frame(link, sid, CLOSE)

    def close_stream(self, sid):
        s = self.streams.pop(sid, None)
        if s:
            s["w"].close()
            log(self.journal, f"close sid={sid} {s['target']} up={s['up']} down={s['down']} "
                              f"secs={time.monotonic() - s['t']:.0f}")

    async def session(self, argv):
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, limit=CHUNK * 4)
        link = proc.stdin
        self.drain_lock = asyncio.Lock()
        log(self.journal, f"link up pid={proc.pid}")
        tasks = set()
        try:
            while True:
                sid, kind, data = await read_frame(proc.stdout)
                if kind == OPEN and len(data) > MAX_TARGET:
                    log(self.journal, f"deny sid={sid} target too long, {len(data)} bytes")
                    send_frame(link, sid, OPENED, b"400 target too long")
                elif kind == OPEN:
                    target = data.decode("ascii", "replace")
                    if target in self.allow:
                        task = asyncio.create_task(self.open_stream(link, sid, target))
                        tasks.add(task)
                        task.add_done_callback(tasks.discard)
                    else:
                        # Цель пришла из контейнера: перевод строки подделал бы запись журнала.
                        log(self.journal, f"deny sid={sid} {UNSAFE.sub('_', target)}")
                        send_frame(link, sid, OPENED, b"403 not in allowlist")
                elif kind == DATA and sid in self.streams:
                    stream = self.streams[sid]
                    stream["up"] += len(data)
                    stream["w"].write(data)
                    try:
                        await stream["w"].drain()
                    except (ConnectionError, OSError):
                        self.close_stream(sid)  # умер один поток, линия живёт
                elif kind == CLOSE:
                    self.close_stream(sid)
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            for task in list(tasks):
                task.cancel()
            for sid in list(self.streams):
                self.close_stream(sid)
            link.close()
            if proc.returncode is None:
                proc.kill()
            await proc.wait()
            log(self.journal, f"link down rc={proc.returncode}")


async def run_out(args):
    journal = open(args.journal, "a") if args.journal else sys.stdout
    outer = Outer(set(args.allow), journal)
    delay = 1
    while True:
        started = time.monotonic()
        try:
            await outer.session(args.command)
        except OSError as e:
            log(journal, f"link error {type(e).__name__}")
        if time.monotonic() - started > 30:
            delay = 1
        log(journal, f"retry in {delay}s")
        await asyncio.sleep(delay)
        delay = min(delay * 2, 30)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    a = sub.add_parser("in")
    a.add_argument("--listen", default="127.0.0.1:18190")
    a.add_argument("--link", default="/run/botfix/bot/link.sock")
    a = sub.add_parser("attach")
    a.add_argument("--link", default="/run/botfix/bot/link.sock")
    a = sub.add_parser("out")
    a.add_argument("--allow", action="append", required=True)
    a.add_argument("--journal")
    a.add_argument("command", nargs="+")
    args = p.parse_args()
    if args.mode == "attach":
        run_attach(args)
    else:
        try:
            asyncio.run(run_in(args) if args.mode == "in" else run_out(args))
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
