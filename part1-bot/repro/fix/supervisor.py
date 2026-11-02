#!/usr/bin/env python3
"""Простой супервизор: держит живыми relay-in и бота, запускает плановые задания.

Запускается из entrypoint как PID 1: собирает зомби и не убивается сигналом изнутри контейнера.
Нужен, потому что cron и systemd на сервере заглушки. Настройки в botfix.env.
"""
import contextlib
import os
import pathlib
import signal
import subprocess
import sys
import time

FIX = "/opt/botfix"
CONF = f"{FIX}/botfix.env"
PY = sys.executable


def read_env(path):
    env = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip("'\"")
    return env


conf = read_env(CONF)
LOG_DIR = pathlib.Path(conf["LOG_DIR"])
STATE_DIR = pathlib.Path(conf["STATE_DIR"])
UID = int(conf["BOT_UID"])
running = {}  # pid -> имя


def say(msg):
    with open(LOG_DIR / "supervisor.log", "a") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")


def spawn(name, argv, cwd=None, env=None, uid=None):
    # Службы пишут журнал, у заданий остаётся только вывод последнего запуска.
    log = open(LOG_DIR / f"{name}.log", "ab") if name in SERVICES else open(STATE_DIR / f"{name}.out", "wb")
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                            user=uid, group=uid, extra_groups=[] if uid is not None else None)
    log.close()
    running[proc.pid] = name
    say(f"start {name} pid={proc.pid}")


def start_relay():
    spawn("relay-in", [PY, "-u", f"{FIX}/relay.py", "in", "--listen", conf["RELAY_LISTEN"],
                       "--link", f"{STATE_DIR}/link.sock"], uid=UID)


def start_bot():
    # Значения .env читаются при каждом старте: новый токен применяется без правки супервизора.
    env = {"PATH": os.environ.get("PATH", ""), "HOME": conf["BOT_DIR"]}
    env.update(read_env(conf["BOT_ENV"]))
    env["POLL_FILE"] = conf["POLL_FILE"]
    spawn("bot", [PY, "-u", f"{FIX}/heartbeat.py", conf["BOT_MODULE"]],
          cwd=conf["BOT_DIR"], env=env, uid=UID)


SERVICES = {"relay-in": start_relay, "bot": start_bot}
JOBS = {"health": ([PY, f"{FIX}/healthcheck.py"], int(conf.get("HEALTH_EVERY", 30))),
        "backup": ([f"{FIX}/backup.sh"], int(conf.get("BACKUP_EVERY", 86400)))}


def stop(*_):
    say("stop")
    for pid in running:
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    os.chown(STATE_DIR, UID, UID)
    pathlib.Path(STATE_DIR, "link.sock").unlink(missing_ok=True)
    pathlib.Path(STATE_DIR, "supervisor.pid").write_text(str(os.getpid()))

    now = time.monotonic()
    due = {name: now for name in SERVICES}  # когда поднимать службу
    delay = {name: 1 for name in SERVICES}
    started = {}
    next_job = {name: now + every for name, (_, every) in JOBS.items()}

    while True:
        while True:  # waitpid(-1) собирает и своих детей, и чужих зомби
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == 0:
                break
            name = running.pop(pid, None)
            if name in SERVICES:
                up = time.monotonic() - started[name]
                delay[name] = 1 if up > 60 else min(delay[name] * 2, 60)
                due[name] = time.monotonic() + delay[name]
                say(f"exit {name} pid={pid} status={os.waitstatus_to_exitcode(status)} "
                    f"after {up:.0f}s, restart in {delay[name]}s")
        now = time.monotonic()
        for name, start in SERVICES.items():
            if name in due and now >= due[name]:
                del due[name]
                started[name] = now
                start()
        for name, (argv, every) in JOBS.items():
            if now >= next_job[name] and name not in running.values():
                next_job[name] = now + every
                spawn(name, argv)
        time.sleep(1)


if __name__ == "__main__":
    main()
