"""Сценарии модели. conf идёт демону tspu.py, nft дописывается в цепочку fwd."""
QUEUE = "ct direction original ct original packets < 10 queue num 0"
SCENARIOS = {
    "off":  {"conf": None, "nft": "", "desc": "модель выключена, только задержка линии"},
    "pass": {"conf": {}, "nft": QUEUE, "desc": "NFQUEUE включён, правил нет: цена самой модели"},
    "sni_rst": {"conf": {"sni": "rst"}, "desc": "S1 SNI-I: ответ сервера превращается в RST/ACK",
                "nft": "ct mark 0x2 ct direction reply queue num 0\n" + QUEUE},
    "sni_drop": {"conf": {"sni": "drop"}, "desc": "S1 SNI-IV: дроп потока с обеих сторон", "nft": QUEUE},
    "quic_all": {"conf": {"quic": "all", "quic_resid": 420}, "desc": "S2 период B: любой QUIC v1 к UDP/443", "nft": QUEUE},
    "quic_sni": {"conf": {"quic": "sni", "quic_resid": 420}, "desc": "S2 период C: SNI из Initial, все UDP-порты", "nft": QUEUE},
    "vpn_sig": {"conf": {"vpn_sig": True}, "desc": "S9: рукопожатия WireGuard и OpenVPN", "nft": QUEUE},
    "curtain_tls": {"conf": {"curtain": "tls"}, "desc": "S3 исходный: TLS к хостингу, ответ больше 16 КиБ, заморозка без RST",
                    "nft": "ct mark 0x4 ct direction reply ct reply bytes > 16384 drop\n" + QUEUE},
    "curtain_all": {"conf": {"curtain": "all"}, "desc": "S3 upd5: 25 пакетов в любую сторону, TCP и UDP, UDP-бан адреса 10 минут",
                    "nft": "ct mark 0x8 accept\n"
                           "meta l4proto udp ip daddr @hosting ct original packets > 25 update @uban { ip daddr timeout 600s } drop\n"
                           "ip daddr @hosting ct original packets > 25 drop\n"
                           "ip saddr @hosting ct reply packets > 25 drop\n" + QUEUE},
    "fet_gfw": {"conf": {"fet": "gfw", "fet_resid": 180}, "desc": "S8 (GFW, не ТСПУ): Ex1-Ex5 по первому пакету, к хостингу, детерминированно", "nft": QUEUE},
    "fet_ru": {"conf": {"fet": "ru"}, "desc": "S7: не-TLS снаружи, HTTPS-рисунок внутри",
               "nft": "meta l4proto tcp ct packets < 80 queue num 0\n"},
    "conn_limit": {"conf": {"conn_limit": 12, "conn_window": 30, "conn_resid": 60},
                   "desc": "S6, S15: больше 12 TLS-соединений к адресу:443 за 30 с, блок пары на 60 с", "nft": QUEUE},
    "wl_ip": {"conf": None, "desc": "S10, S11: режим белого списка: наружу только в 10.10.2.128/25; SYN проходит, данные нет",
              "nft": "ip saddr 10.10.1.0/24 ip daddr != 10.10.2.128/25 tcp flags syn accept\n"
                     "ip saddr 10.10.1.0/24 ip daddr != 10.10.2.128/25 drop\n"},
}
