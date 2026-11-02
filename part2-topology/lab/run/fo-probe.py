#!/usr/bin/env python3
"""Непрерывные запросы через SOCKS клиента: новый запрос каждые STEP секунд в своём соединении, зависший не держит следующий.
fo-probe.py <секунд> <объект> <байт> [шаг] [таймаут]. Строка на запрос: начало конец ok байт локальный_порт."""
import socket, struct, sys, threading, time
D, OBJ, WANT = float(sys.argv[1]), sys.argv[2], int(sys.argv[3])
STEP = float(sys.argv[4]) if len(sys.argv) > 4 else 0.25
TMO = float(sys.argv[5]) if len(sys.argv) > 5 else 4.0
lock = threading.Lock()
def req():
    t0 = time.time(); end = t0 + TMO; got = 0; port = 0; s = socket.socket()
    try:
        s.settimeout(TMO); s.connect(("127.0.0.1", 10801)); port = s.getsockname()[1]
        s.sendall(b"\x05\x01\x00"); s.recv(2)
        s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 8080))
        if s.recv(10)[1:2] == b"\x00":
            s.sendall(f"GET /{OBJ} HTTP/1.0\r\nHost: lab\r\n\r\n".encode())
            buf = b""
            while time.time() < end and got < WANT:
                s.settimeout(max(0.05, end - time.time()))
                c = s.recv(65536)
                if not c:
                    break
                if buf is None:
                    got += len(c)
                else:
                    buf += c
                    if b"\r\n\r\n" in buf:
                        got = len(buf.split(b"\r\n\r\n", 1)[1]); buf = None
    except OSError:
        pass
    s.close()
    with lock:
        print(f"{t0:.3f} {time.time():.3f} {int(got == WANT)} {got} {port}", flush=True)
stop = time.time() + D
while time.time() < stop:
    threading.Thread(target=req, daemon=True).start()
    time.sleep(STEP)
time.sleep(TMO + 0.3)
