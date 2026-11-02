#!/opt/tspu-venv/bin/python3
"""ctl.py net | set <сценарий> | reset | show"""
import os, signal, subprocess, sys, time
sys.path.insert(0, "/opt/lab")
from scenarios import SCENARIOS
PID = "/run/tspu.pid"; STATE = "/run/tspu.scenario"
BASE = """
table inet tspu {{
  set hosting {{ type ipv4_addr; flags interval; elements = {{ 10.10.2.0/25 }} }}
  set resid3 {{ type ipv4_addr . ipv4_addr . inet_service; flags timeout; }}
  set pair {{ type ipv4_addr . ipv4_addr; flags timeout; }}
  set q4 {{ type ipv4_addr . inet_service . ipv4_addr . inet_service; flags timeout; }}
  set uban {{ type ipv4_addr; flags dynamic,timeout; }}
  chain fw {{ type filter hook forward priority 0; policy accept;
    ct mark 0x1 drop
    ip saddr . ip daddr . th dport @resid3 drop
    ip saddr . ip daddr @pair drop
    ip daddr . ip saddr @pair drop
    ip saddr . udp sport . ip daddr . udp dport @q4 drop
    ip daddr @uban drop
    {rules}
  }}
  chain post {{ type filter hook forward priority 10; policy accept;
    meta mark 0x1 ct mark set 0x1 drop
    meta mark 0x2 ct mark set 0x2
    meta mark 0x4 ct mark set 0x4
    meta mark 0x8 ct mark set 0x8
  }}
}}
"""
def sh(*a):
    return subprocess.run(a, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
def stop():
    if os.path.exists(PID):
        try:
            os.kill(int(open(PID).read()), signal.SIGTERM)
            for _ in range(100):
                os.kill(int(open(PID).read()), 0); time.sleep(0.01)
        except (ProcessLookupError, ValueError):
            pass
        os.remove(PID)
def start(sc):
    if SCENARIOS[sc]["conf"] is None:
        return
    p = subprocess.Popen(["/opt/tspu-venv/bin/python3", "/opt/lab/tspu.py", sc], cwd="/opt/lab",
                         stdout=open("/var/log/tspu.log", "a"), stderr=subprocess.STDOUT)
    open(PID, "w").write(str(p.pid))
    for _ in range(300):
        t = open("/proc/net/netfilter/nfnetlink_queue").read() if os.path.exists("/proc/net/netfilter/nfnetlink_queue") else ""
        if t.strip():
            return
        time.sleep(0.01)
    sys.exit("демон не привязался к очереди")
def load(sc):
    sh("nft", "delete", "table", "inet", "tspu")
    if sc != "off":
        r = subprocess.run(["nft", "-f", "-"], input=BASE.format(rules=SCENARIOS[sc]["nft"]), text=True, capture_output=True)
        if r.returncode:
            sys.exit(r.stderr)
    open(STATE, "w").write(sc)
cmd = sys.argv[1]
if cmd == "net":
    for i in ("lana", "lanb"):
        sh("ethtool", "-K", i, "tso", "off", "gso", "off", "gro", "off", "lro", "off")
        sh("tc", "qdisc", "del", "dev", i, "root")  # replace сохранил бы прежний rate
        sh("tc", "qdisc", "replace", "dev", i, "root", "netem", "delay", "20ms", "limit", "20000")
    sh("sysctl", "-q", "net.ipv4.ip_forward=1", "net.netfilter.nf_conntrack_acct=1", "net.netfilter.nf_conntrack_tcp_be_liberal=1")
elif cmd == "set":
    stop(); load(sys.argv[2]); sh("conntrack", "-F"); start(sys.argv[2])
elif cmd == "reset":
    sc = open(STATE).read(); stop(); load(sc); sh("conntrack", "-F"); start(sc)
elif cmd == "show":
    print(open(STATE).read())
