#!/opt/tspu-venv/bin/python3
"""Модель активного зондирования: что видит сканер, который сам подключается к сервису.
Запуск на tspu (адрес 10.10.2.1, модель в обход). Пишет CSV в stdout. probe.py [повторов]"""
import asyncio, csv, hashlib, os, socket, ssl, sys, time
REPS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
TCP = [("https", "10.10.2.10", 443), ("reality", "10.10.2.11", 443), ("xhttp", "10.10.2.12", 443),
       ("ss2022", "10.10.2.13", 8388), ("ovpn-tcp", "10.10.2.17", 443)]
UDP = [("wg", "10.10.2.14", 51820), ("awg", "10.10.2.15", 51821), ("ovpn-udp", "10.10.2.16", 1194),
       ("hy2", "10.10.2.11", 443), ("hy2-obfs", "10.10.2.18", 443)]
w = csv.writer(sys.stdout); w.writerow(["target", "probe", "rep", "result", "bytes", "elapsed_s", "note"])

def tcp_probe(ip, port, data, wait=4):
    s = socket.create_connection((ip, port), timeout=3); s.settimeout(wait)
    t0 = time.time(); s.sendall(data); got = 0; first = b""
    try:
        while True:
            b = s.recv(4096)
            if not b:
                return "fin", got, time.time() - t0, first[:12].hex()
            got += len(b); first = first or b
    except socket.timeout:
        return "timeout", got, time.time() - t0, first[:12].hex()
    except ConnectionResetError:
        return "rst", got, time.time() - t0, first[:12].hex()
    finally:
        s.close()

def tls_probe(ip, port, sni):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.check_hostname = False; c.verify_mode = ssl.CERT_NONE
    t0 = time.time()
    try:
        s = socket.create_connection((ip, port), timeout=3)
        t = c.wrap_socket(s, server_hostname=sni); der = t.getpeercert(True)
        r = f"{t.version()} cert={hashlib.sha256(der).hexdigest()[:12]}"; t.close()
        return "tls_ok", 0, time.time() - t0, r
    except Exception as e:
        return "tls_fail", 0, time.time() - t0, type(e).__name__

def udp_probe(ip, port, data, wait=2):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(wait); t0 = time.time()
    s.sendto(data, (ip, port))
    try:
        b = s.recv(4096); return "reply", len(b), time.time() - t0, b[:8].hex()
    except socket.timeout:
        return "silent", 0, time.time() - t0, ""
    finally:
        s.close()

async def quic_probe(ip, port, sni):
    from aioquic.asyncio import connect
    from aioquic.quic.configuration import QuicConfiguration
    t0 = time.time(); cfg = QuicConfiguration(is_client=True, alpn_protocols=["h3"], verify_mode=ssl.CERT_NONE, server_name=sni)
    try:
        async with asyncio.timeout(3):
            async with connect(ip, port, configuration=cfg):
                pass
        return "quic_ok", 0, time.time() - t0, ""
    except Exception as e:
        return "quic_fail", 0, time.time() - t0, type(e).__name__

for rep in range(1, REPS + 1):
    for n, ip, port in TCP:
        for name, fn in (("random64", lambda: tcp_probe(ip, port, os.urandom(64))),
                         ("http_get", lambda: tcp_probe(ip, port, b"GET / HTTP/1.1\r\nHost: probe\r\n\r\n")),
                         ("tls_listed_sni", lambda: tls_probe(ip, port, "allowed.example")),
                         ("tls_unlisted_sni", lambda: tls_probe(ip, port, "unlisted.example"))):
            try:
                r = fn()
            except OSError as e:
                r = ("connect_fail", 0, 0, type(e).__name__)
            w.writerow([n, name, rep, r[0], r[1], f"{r[2]:.3f}", r[3]])
    for n, ip, port in UDP:
        r = udp_probe(ip, port, os.urandom(1200)); w.writerow([n, "random1200", rep, r[0], r[1], f"{r[2]:.3f}", r[3]])
        r = asyncio.run(quic_probe(ip, port, "allowed.example")); w.writerow([n, "quic_v1_h3", rep, r[0], r[1], f"{r[2]:.3f}", r[3]])
    sys.stdout.flush()
