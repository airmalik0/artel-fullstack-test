#!/usr/bin/env python3
"""Замер переключения клиента. Запуск на маке, один отсчёт времени на всё: момент отказа и приход строк пробы.
Метрика: от отправки команды отказа до конца первого успешного запроса через запасной путь.
Путь каждого запроса берётся из журнала sing-box по локальному порту, а не выводится из времени.
Строка недействительна (valid=0), если перед отказом активен не Reality, запрос до отказа шёл мимо Reality
или отказ не задел запросы. Такие строки остаются в CSV и повторяются.
failover.py --out results/failover.csv --reps 10 [--cases имя,имя] [--append]"""
import argparse, csv, json, os, random, re, statistics, subprocess, threading, time
WORK = os.environ.get("LAB_WORK", os.path.expanduser("~/Projects/artel-test-work/part2/vm"))
RAW = os.path.expanduser("~/Projects/artel-test-work/part2/raw/fo")
PORT = {"client": 2221, "tspu": 2222, "server": 2223}
PRIMARY = "reality"
LAST = {}  # момент отказа и сдвиг часов последнего прогона, для журнала сторожа
def sshv(vm):
    return ["ssh", "-i", f"{WORK}/lab_ed25519", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ControlMaster=auto", "-o", "ControlPersist=600",
            "-o", f"ControlPath={WORK}/run/%r@%h:%p", "-p", str(PORT[vm]), "lab@127.0.0.1"]
def ssh(vm, cmd, t=60):
    return subprocess.run(sshv(vm) + [cmd], capture_output=True, text=True, timeout=t).stdout
FAULT_TABLE = ("sudo nft delete table inet fault 2>/dev/null; sudo nft add table inet fault; "
               "sudo nft add chain inet fault fw '{ type filter hook forward priority 0; policy accept; }'")
FAULTS = {
    "model_sni": ("tspu", "sudo /opt/lab/ctl.py set sni_drop"),        # SNI Reality попал в блоклист: дроп, новые потоки не живут
    "model_curtain": ("tspu", "sudo /opt/lab/ctl.py set curtain_tls"), # заморозка на объёме, маленькие запросы идут
    "model_curtain_all": ("tspu", "sudo /opt/lab/ctl.py set curtain_all"),  # счёт пакетов, задевает и UDP
    "service_stop": ("server", "sudo bash /tmp/provision/fo-server.sh xray-stop"),  # порт закрыт, клиент получает RST
    "ip_ban": ("tspu", "sudo nft add rule inet fault fw ip daddr 10.10.2.11 drop"),  # дроп без ответа, A недоступен целиком
}
#         имя: (механизм, интервал, отказ, объект, окно после отказа)
CASES = {f"{m}_{f}": (m.rstrip("0123456789"), int(re.search(r"\d+", m).group()), f, "1k", 25 + 3 * int(re.search(r"\d+", m).group()))
         for m in ("urltest15", "urltest5", "watchdog5") for f in ("model_sni", "service_stop", "ip_ban")}
CASES["urltest15_model_curtain"] = ("urltest", 15, "model_curtain", "256k", 70)
SIZE = {"1k": 1024, "256k": 262144}
HEAD = ["case", "mech", "interval_s", "fault", "obj", "rep", "valid", "why_invalid", "now_before", "pre_ok", "pre_total", "pre_via",
        "pre_s", "fault_cmd_s", "first_ok_fallback_s", "fallback_path", "gap_s", "failed_after", "now_after", "window_s", "load1"]
def reset():
    ssh("client", "sudo /opt/lab/sbctl.sh stop")
    ssh("tspu", "sudo /opt/lab/ctl.py set off; " + FAULT_TABLE)
    ssh("server", "sudo bash /tmp/provision/fo-server.sh ensure")
def now_path():
    try:
        return json.loads(ssh("client", "curl -s --max-time 2 http://127.0.0.1:9090/proxies/auto")).get("now", "")
    except (ValueError, subprocess.TimeoutExpired):
        return ""
class Probe:
    """fo-probe.py на client, строки читаются сразу. offset переводит время ВМ в время мака."""
    def __init__(self, dur, obj):
        cmd = f"echo $$ > /tmp/fop.pid; exec python3 /opt/lab/fo-probe.py {dur} {obj} {SIZE[obj]}"
        self.p = subprocess.Popen(sshv("client") + [cmd], stdout=subprocess.PIPE, text=True)
        self.rows = []; self.offs = []
        self.t = threading.Thread(target=self.read, daemon=True); self.t.start()
    def read(self):
        for l in self.p.stdout:
            t0, t1, ok, got, port = l.split()
            self.offs.append(time.time() - float(t1))
            self.rows.append((float(t0), float(t1), int(ok), int(got), int(port)))
    def stop(self):
        ssh("client", "kill $(cat /tmp/fop.pid) 2>/dev/null")
        self.p.wait(timeout=15); self.t.join(timeout=5)
    @property
    def offset(self):
        return min(self.offs)
def path_by_port(log):
    """Журнал sing-box: id соединения -> локальный порт клиента и выбранный outbound."""
    port, tag = {}, {}
    for l in log.splitlines():
        m = re.search(r"\[(\d+) [^\]]*\] inbound/socks\[[^\]]*\]: inbound connection from 127\.0\.0\.1:(\d+)", l)
        if m:
            port[m.group(1)] = int(m.group(2)); continue
        m = re.search(r"\[(\d+) [^\]]*\] outbound/\w+\[(\w+)\]: outbound connection to", l)
        if m and m.group(2) != "auto":
            tag[m.group(1)] = m.group(2)
    return {port[i]: tag[i] for i in port if i in tag}
def start_client(mech, interval, tol=300):
    if mech == "urltest":
        ssh("client", f"sudo /opt/lab/sbctl.sh start urltest {interval}s {tol}")
    else:
        ssh("client", f"sudo /opt/lab/sbctl.sh start selector {interval} 256k")
def run_once(name, c, rep, tol=300):
    mech, interval, fault, obj, win = c
    reset(); start_client(mech, interval, tol)
    time.sleep(3)
    pre = 6 + random.uniform(0, 2 * interval)
    probe = Probe(pre + win + 2, obj)
    time.sleep(pre)
    now_before = now_path()
    vm, cmd = FAULTS[fault]
    t_fault = time.time(); ssh(vm, cmd); t_ack = time.time()
    stop_at = t_ack + win
    while time.time() < stop_at:
        late = [r for r in list(probe.rows) if r[2] and r[0] + probe.offset > t_ack + 0.5]
        if len(late) >= 6:
            time.sleep(0.5); break
        time.sleep(0.2)
    now_after = now_path()
    probe.stop()
    log = ssh("client", "sudo cat /tmp/sb.log")
    os.makedirs(RAW, exist_ok=True); open(f"{RAW}/{name}-{rep}-{int(t_fault)}.log", "w").write(log)
    via = path_by_port(log); off = probe.offset
    LAST.update(t_fault=t_fault, off=off)
    rows = sorted(probe.rows, key=lambda r: r[1])
    before = [r for r in rows if r[1] + off < t_fault]
    pre_via = sorted({via.get(r[4], "?") for r in before if r[2]})
    after = [r for r in rows if r[1] + off >= t_fault]
    fb = next((r for r in after if r[2] and via.get(r[4], "?") not in (PRIMARY, "?")), None)
    failed = sum(1 for r in after if not r[2] and (fb is None or r[1] <= fb[1]))
    last_ok = max((r[1] for r in rows if r[2] and (fb is None or r[1] < fb[1])), default=None)
    why = []
    if now_before != PRIMARY: why.append(f"now={now_before}")
    if pre_via != [PRIMARY]: why.append("pre_via")
    if len([r for r in before if r[2]]) < 0.8 * max(1, len(before)): why.append("pre_fail")
    if failed == 0: why.append("no_failure_seen")
    return dict(zip(HEAD, [name, mech, interval, fault, obj, rep, int(not why), ";".join(why), now_before,
                sum(r[2] for r in before), len(before), "+".join(pre_via), f"{pre:.2f}", f"{t_ack - t_fault:.3f}",
                f"{fb[1] + off - t_fault:.2f}" if fb else "", via.get(fb[4], "") if fb else "",
                f"{fb[1] - last_ok:.2f}" if fb and last_ok else "", failed, now_after, win, f"{os.getloadavg()[0]:.1f}"]))
def main():
    a = argparse.ArgumentParser(); a.add_argument("--out", required=True); a.add_argument("--reps", type=int, default=10)
    a.add_argument("--cases", default=",".join(CASES)); a.add_argument("--append", action="store_true")
    a.add_argument("--tolerance", type=int, default=300); o = a.parse_args()
    new = not (o.append and os.path.exists(o.out))
    f = open(o.out, "w" if new else "a", newline=""); w = csv.DictWriter(f, HEAD)
    if new: w.writeheader()
    ssh("tspu", "sudo modprobe nfnetlink_queue; sudo /opt/lab/ctl.py net")
    for name in o.cases.split(","):
        done = tries = 0
        while done < o.reps and tries < 2 * o.reps:
            tries += 1
            r = run_once(name, CASES[name], tries, o.tolerance)
            w.writerow(r); f.flush(); done += r["valid"]
            print(name, tries, r["valid"], r["why_invalid"], r["now_before"], r["first_ok_fallback_s"], r["fallback_path"], flush=True)
    ssh("client", "sudo /opt/lab/sbctl.sh stop")
    ssh("tspu", "sudo /opt/lab/ctl.py set off; sudo nft delete table inet fault")
    ssh("server", "sudo bash /tmp/provision/fo-server.sh restore")
if __name__ == "__main__":
    main()
