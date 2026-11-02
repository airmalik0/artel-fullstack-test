#!/usr/bin/env python3
"""Лаунчер формы сервера, мой: читает .env от root, сбрасывает права на 10001, запускает бота."""
import fcntl
import os
import subprocess
import sys

from dotenv import dotenv_values

ROOT = "/opt/bots/amigo"
os.environ.update({k: v for k, v in dotenv_values(f"{ROOT}/.env").items() if v is not None})
os.setgroups([])
os.setgid(10001)
os.setuid(10001)
os.chdir(ROOT)
lock = open(f"{ROOT}/data/prod.lock", "a+")
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
with open("/var/log/amigo/amigo.log", "a", buffering=1) as log:
    raise SystemExit(subprocess.call([sys.executable, "-B", "-u", "-m", "amigo.main"], stdout=log, stderr=log))
