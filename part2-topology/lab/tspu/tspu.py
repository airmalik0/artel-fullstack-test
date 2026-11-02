#!/opt/tspu-venv/bin/python3
"""Модель поведений ТСПУ на NFQUEUE. Не воспроизведение настоящего ТСПУ.
Каждое правило повторяет опубликованное наблюдение; ссылки в SOURCES рядом с правилом
и в ../README.md. Обратные ссылки S1..S14 совпадают с разделом «Источники» TOPOLOGY.md.
Запуск: tspu.py <сценарий>. Сценарии и nft-правила: scenarios.py."""
import socket, struct, subprocess, sys, time, signal
from netfilterqueue import NetfilterQueue
from quic import parse_initial_sni

BLOCK_SNI = {b"blocked.example"}      # блоклист SNI (S1, S2: один список для TCP и QUIC)
ALLOW_SNI = {b"allowed.example"}      # белый список SNI под «занавесом» (S3 upd3)
MARK_DROP, MARK_RST, MARK_CURTAIN, MARK_EXEMPT = 1, 2, 4, 8
HOSTING = ("10.10.2.", 0, 127)        # «зарубежный хостинг»: .0-.127; .128-.255 нет

def is_hosting(ip):
    a = ip.split(".")
    return ip.startswith(HOSTING[0]) and HOSTING[1] <= int(a[3]) <= HOSTING[2]

def nft(cmd):
    subprocess.run(["nft", cmd], check=False, stderr=subprocess.DEVNULL)

def tls_sni(buf):
    """SNI из ClientHello; None, если записи не хватает; b'' если SNI нет."""
    if len(buf) < 5 or buf[0] != 0x16 or buf[1] != 3:
        return b""
    need = 5 + struct.unpack("!H", buf[3:5])[0]
    if len(buf) < need:
        return None
    return sni_from_hello(buf[5:need])

def sni_from_hello(h):
    try:
        if h[0] != 1:
            return b""
        i = 4 + 2 + 32
        i += 1 + h[i]
        i += 2 + struct.unpack("!H", h[i:i + 2])[0]
        i += 1 + h[i]
        end = i + 2 + struct.unpack("!H", h[i:i + 2])[0]
        i += 2
        while i + 4 <= end:
            t, l = struct.unpack("!HH", h[i:i + 4])
            if t == 0:
                nl = struct.unpack("!H", h[i + 7:i + 9])[0]
                return bytes(h[i + 9:i + 9 + nl])
            i += 4 + l
    except (IndexError, struct.error):
        pass
    return b""

def fet_suspicious(p):
    """Правила Ex1-Ex5 из Wu et al. (S8). Это наблюдение за GFW, не за ТСПУ.
    True: первый пакет похож на полностью зашифрованный поток."""
    if not p:
        return False
    pop = sum(bin(b).count("1") for b in p) / len(p)
    if pop <= 3.4 or pop >= 4.6:
        return False
    pr = [0x20 <= b <= 0x7e for b in p]
    if all(pr[:6]) and len(p) >= 6:
        return False
    if sum(pr) * 2 > len(p):
        return False
    run = best = 0
    for x in pr:
        run = run + 1 if x else 0
        best = max(best, run)
    if best > 20:
        return False
    if len(p) >= 3 and p[0] in (0x16, 0x17) and p[1] == 3 and p[2] <= 9:
        return False
    if p[:4] in (b"GET ", b"PUT ", b"POST", b"HEAD"):
        return False
    return True

def wg_handshake(p):
    # Формат: WireGuard whitepaper, раздел 5.4. Тип 1 (148 байт) или 2 (92 байта), три нулевых байта.
    return (len(p) == 148 and p[:4] == b"\x01\0\0\0") or (len(p) == 92 and p[:4] == b"\x02\0\0\0")

def ovpn_reset(p, tcp):
    # P_CONTROL_HARD_RESET_CLIENT_V2: опкод 7 в старших пяти битах, key id 0.
    if tcp:
        return len(p) >= 3 and struct.unpack("!H", p[:2])[0] == len(p) - 2 and p[2] == 0x38
    return len(p) >= 14 and p[0] == 0x38

class Flow:
    __slots__ = ("buf", "done", "first", "c411", "cn", "sn", "decided", "qbuf")
    def __init__(self):
        self.buf = b""; self.done = False; self.first = True
        self.c411 = 0; self.cn = 0; self.sn = 0; self.decided = False; self.qbuf = []

class Model:
    def __init__(self, sc, conf):
        self.sc = sc; self.c = conf; self.flows = {}; self.conn_seen = {}; self.rst_flows = set()

    def handle(self, pkt):
        d = bytearray(pkt.get_payload())
        ihl = (d[0] & 15) * 4; proto = d[9]
        src = socket.inet_ntoa(bytes(d[12:16])); dst = socket.inet_ntoa(bytes(d[16:20]))
        if proto == 6:
            sp, dp = struct.unpack("!HH", d[ihl:ihl + 4])
            off = ihl + (d[ihl + 12] >> 4) * 4; flags = d[ihl + 13]; pl = bytes(d[off:])
        elif proto == 17:
            sp, dp = struct.unpack("!HH", d[ihl:ihl + 4]); pl = bytes(d[ihl + 8:]); flags = 0; off = ihl + 8
        else:
            return pkt.accept()
        out = src.startswith("10.10.1.")      # направление изнутри наружу (S1: только изнутри)
        key = (src, sp, dst, dp, proto) if out else (dst, dp, src, sp, proto)
        fl = self.flows.get(key) or self.flows.setdefault(key, Flow())
        fl.cn += out; fl.sn += not out
        if not out and key in self.rst_flows:
            return self.rewrite_rst(pkt, d, ihl, off)
        if proto == 6:
            return self.tcp(pkt, fl, key, out, pl, flags)
        return self.udp(pkt, fl, key, out, pl)

    def rewrite_rst(self, pkt, d, ihl, off):
        # S1, SNI-I: усечь нагрузку и сменить флаги на RST/ACK, seq/ack и TTL не менять.
        d = d[:off]; d[ihl + 13] = 0x14
        d[2:4] = struct.pack("!H", len(d)); d[10:12] = b"\0\0"
        d[10:12] = struct.pack("!H", csum(d[:ihl]))
        d[ihl + 16:ihl + 18] = b"\0\0"
        ph = bytes(d[12:20]) + struct.pack("!BBH", 0, 6, len(d) - ihl)
        d[ihl + 16:ihl + 18] = struct.pack("!H", csum(ph + bytes(d[ihl:])))
        pkt.set_payload(bytes(d)); pkt.accept()

    def tcp(self, pkt, fl, key, out, pl, flags):
        c = self.c
        if not pl:
            return pkt.accept()
        if out and not fl.done:
            fl.buf += pl
            first_data = fl.first; fl.first = False
            sni = tls_sni(fl.buf)
            if sni is None and len(fl.buf) < 8192:
                return pkt.accept()               # ждём остаток ClientHello
            fl.done = True
            tlsish = fl.buf[:2] == b"\x16\x03"
            if c.get("vpn_sig") and ovpn_reset(pl, True):
                return self.freeze(pkt, key)
            if tlsish and sni in BLOCK_SNI and c.get("sni"):
                if c["sni"] == "rst":
                    self.rst_flows.add(key); pkt.set_mark(MARK_RST); return pkt.accept()
                return self.freeze(pkt, key)      # S1, SNI-IV: дроп с обеих сторон, включая ClientHello
            if c.get("curtain") and is_hosting(key[2]):
                ssh = fl.buf[:4] == b"SSH-"       # S3 upd2: SSH не ограничивается
                if sni in ALLOW_SNI or ssh:
                    pkt.set_mark(MARK_EXEMPT)
                elif tlsish or c["curtain"] == "all":
                    pkt.set_mark(MARK_CURTAIN)
                return pkt.accept()
            if c.get("fet") == "gfw" and is_hosting(key[2]) and fet_suspicious(fl.buf if first_data else pl):
                nft(f"add element inet tspu resid3 {{ {key[0]} . {key[2]} . {key[3]} timeout {c['fet_resid']}s }}")
                return self.freeze(pkt, key)
            if c.get("conn_limit") and tlsish and key[3] == 443:
                return self.count_conn(pkt, key)
        if c.get("fet") == "ru" and is_hosting(key[2]) and not fl.decided:
            # S7: не TLS снаружи, клиент дал >=3 пакетов >=411 байт, сервер шлёт чаще клиента.
            if fl.cn + fl.sn > 3 and fl.buf[:2] != b"\x16\x03":
                if out and len(pl) >= 411:
                    fl.c411 += 1
                if fl.c411 >= 3 and fl.sn > fl.cn:
                    fl.decided = True; return self.freeze(pkt, key)
        return pkt.accept()

    def count_conn(self, pkt, key):
        # S6, S15: лимит одновременных TLS-соединений к одному адресу:443, отчёт S15 называет порог 12.
        now = time.time(); pair = (key[0], key[2])
        w = [t for t in self.conn_seen.get(pair, []) if now - t < self.c["conn_window"]]
        w.append(now); self.conn_seen[pair] = w
        if len(w) > self.c["conn_limit"]:
            nft(f"add element inet tspu pair {{ {key[0]} . {key[2]} timeout {self.c['conn_resid']}s }}")
            return pkt.drop()
        return pkt.accept()

    def udp(self, pkt, fl, key, out, pl):
        c = self.c
        if not out or not pl:
            return pkt.accept()
        if c.get("vpn_sig") and (wg_handshake(pl) or ovpn_reset(pl, False)):
            return self.freeze(pkt, key)
        if c.get("quic") == "all" and fl.first:
            fl.first = False
            # S2, период B: первый пакет к 443 от 1001 байта с QUIC v1; иначе residual clearance.
            if key[3] == 443 and len(pl) >= 1001 and pl[0] & 0x80 and pl[1:5] == b"\0\0\0\1":
                return self.q4(pkt, key)
        if c.get("quic") == "sni" and pl[0] & 0x80 and pl[1:5] == b"\0\0\0\1":
            # S2, период C: дешифровка Initial, только QUIC v1, все UDP-порты.
            sni = parse_initial_sni(pl, fl)
            if sni in BLOCK_SNI:
                return self.q4(pkt, key)
        return pkt.accept()

    def q4(self, pkt, key):
        nft(f"add element inet tspu q4 {{ {key[0]} . {key[1]} . {key[2]} . {key[3]} timeout {self.c['quic_resid']}s }}")
        return pkt.drop()

    def freeze(self, pkt, key):
        pkt.set_mark(MARK_DROP); pkt.accept()

def csum(b):
    if len(b) % 2:
        b = bytes(b) + b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), bytes(b)))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff

def main():
    from scenarios import SCENARIOS
    sc = sys.argv[1]; conf = SCENARIOS[sc]["conf"]
    m = Model(sc, conf); q = NetfilterQueue()
    q.bind(0, m.handle, max_len=8192)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    try:
        q.run()
    finally:
        q.unbind()

if __name__ == "__main__":
    main()
