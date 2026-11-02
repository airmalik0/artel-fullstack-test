"""Разбор QUIC v1 Initial: ключи выводятся из открытого DCID (RFC 9001, раздел 5.2),
поэтому мидлбокс читает ClientHello без секретов. Так работает период C в S2."""
import hashlib, hmac, struct
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SALT = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")

def expand(secret, label, n):
    lab = b"tls13 " + label
    info = struct.pack("!HB", n, len(lab)) + lab + b"\0"
    out = b""; t = b""; i = 1
    while len(out) < n:
        t = hmac.new(secret, t + info + bytes([i]), hashlib.sha256).digest(); out += t; i += 1
    return out[:n]

def varint(b, i):
    n = 1 << (b[i] >> 6)
    v = b[i] & 0x3f
    for j in range(1, n):
        v = v << 8 | b[i + j]
    return v, i + n

def decrypt(pl):
    if pl[0] & 0x30:                       # не Initial
        return None
    i = 5
    dl = pl[i]; dcid = pl[i + 1:i + 1 + dl]; i += 1 + dl
    i += 1 + pl[i]
    tl, i = varint(pl, i); i += tl
    ln, i = varint(pl, i)
    pn_off = i
    sec = hmac.new(SALT, dcid, hashlib.sha256).digest()
    cs = expand(sec, b"client in", 32)
    key, iv, hp = expand(cs, b"quic key", 16), expand(cs, b"quic iv", 12), expand(cs, b"quic hp", 16)
    sample = pl[pn_off + 4:pn_off + 20]
    enc = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
    mask = enc.update(sample)
    first = pl[0] ^ (mask[0] & 0x0f)
    pl_n = (first & 3) + 1
    pn = bytes(pl[pn_off + j] ^ mask[1 + j] for j in range(pl_n))
    hdr = bytes([first]) + pl[1:pn_off] + pn
    nonce = bytes(a ^ b for a, b in zip(iv, b"\0" * (12 - pl_n) + pn))
    return AESGCM(key).decrypt(nonce, pl[pn_off + pl_n:pn_off + ln], hdr)

def frames(p, sink):
    i = 0
    while i < len(p):
        t = p[i]
        if t in (0, 1):
            i += 1
        elif t == 6:
            off, i = varint(p, i + 1)
            ln, i = varint(p, i)
            sink.append((off, p[i:i + ln])); i += ln
        elif t in (2, 3):
            _, i = varint(p, i + 1)
            _, i = varint(p, i)
            r, i = varint(p, i)
            _, i = varint(p, i)
            for _x in range(r):
                _, i = varint(p, i)
                _, i = varint(p, i)
            if t == 3:
                for _x in range(3):
                    _, i = varint(p, i)
        else:
            return

def parse_initial_sni(pl, fl):
    """SNI, если ClientHello собран; None, если нужны ещё пакеты или это не Initial."""
    from tspu import sni_from_hello
    try:
        fr = decrypt(pl)
    except Exception:
        return None
    if fr is None:
        return None
    frames(fr, fl.qbuf)
    buf = bytearray(); pos = 0
    for off, data in sorted(fl.qbuf, key=lambda x: x[0]):
        if off > pos:
            break
        buf += data[pos - off:]; pos = max(pos, off + len(data))
    if len(buf) < 4:
        return None
    need = 4 + int.from_bytes(buf[1:4], "big")
    return sni_from_hello(bytes(buf[:need])) if len(buf) >= need else None
