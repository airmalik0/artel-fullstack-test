#!/usr/bin/env python3
"""Проверка настоящей связности, а не наличия процесса.

GREEN: getMe через реле вернул бота, настоящий процесс бота жив и опрос успешен не дольше MAX_POLL_AGE секунд назад.
Иначе RED с причиной. Код выхода 0 или 1. Смена состояния пишется в LOG_DIR/health.log.
"""
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

CONF = "/opt/botfix/botfix.env"


def read_env(path):
    env = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip("'\"")
    return env


def get_me(token, proxy):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"https": proxy}))
    try:
        with opener.open(f"https://api.telegram.org/bot{token}/getMe", timeout=20) as r:
            return True, "@" + json.load(r)["result"]["username"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return False, "getMe 401 Unauthorized: Telegram не принял токен, нужен новый от BotFather"
        return False, f"getMe HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, f"нет связи с Telegram: {e.reason}"
    except OSError as e:
        return False, f"нет связи с Telegram: {type(e).__name__}"


def bot_running(module):
    """Живой бот это настоящий python с heartbeat.py и модулем в аргументах.

    argv[0] не считается: на сервере приманка подписана через exec -a и обманывает pgrep.
    Без CAP_SYS_PTRACE exe чужого uid не читается, тогда comm: exec -a его тоже не меняет.
    """
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            args = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0")[1:]
            try:
                name = os.path.basename(os.readlink(f"/proc/{pid}/exe"))
            except PermissionError:
                name = pathlib.Path(f"/proc/{pid}/comm").read_text().strip()
        except OSError:
            continue
        if name.startswith("python") and module in args and any(a.endswith("/heartbeat.py") for a in args):
            return True
    return False


def main():
    conf = read_env(CONF)
    token = read_env(conf["BOT_ENV"]).get("BOT_TOKEN", "")
    ok, detail = get_me(token, conf["PROXY"]) if token else (False, "в .env нет BOT_TOKEN")
    state = detail
    max_age = int(conf.get("MAX_POLL_AGE", 60))
    try:
        age = int(time.time() - os.lstat(conf["POLL_FILE"]).st_mtime)
        age_text = f"poll_age={age}s"
    except OSError:
        age, age_text = None, "опроса ещё не было"
    if ok and not bot_running(conf["BOT_MODULE"]):
        ok, state = False, f"getMe {detail} отвечает, но процесса бота нет"
    elif ok and (age is None or age > max_age):
        ok, state = False, f"getMe {detail} отвечает, но бот не опрашивает Telegram дольше {max_age} с"
    word = "GREEN" if ok else "RED"
    line = f"{word} {detail if ok else state}, {age_text}"
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line)

    key = word if ok else state
    last = pathlib.Path(conf["STATE_DIR"]) / "health.last"
    if not last.exists() or last.read_text() != key:
        last.write_text(key)
        with open(pathlib.Path(conf["LOG_DIR"]) / "health.log", "a") as log:
            log.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + line + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
