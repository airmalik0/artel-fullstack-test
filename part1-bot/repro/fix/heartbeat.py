#!/usr/bin/env python3
"""Запускает модуль бота и отмечает каждый успешный getUpdates.

Код бота не меняется: healthcheck.py смотрит на время файла POLL_FILE.
Заодно гасит INFO от httpx: в этих строках URL с токеном.

  POLL_FILE=/run/botfix/last_poll heartbeat.py amigo.main
"""
import logging
import os
import pathlib
import runpy
import sys

import telegram

poll_file = pathlib.Path(os.environ["POLL_FILE"])
original = telegram.Bot.get_updates


async def get_updates(self, *args, **kwargs):
    updates = await original(self, *args, **kwargs)
    poll_file.touch()
    return updates


telegram.Bot.get_updates = get_updates
logging.getLogger("httpx").setLevel(logging.WARNING)
sys.path.insert(0, os.getcwd())
module = sys.argv[1]
sys.argv = [module]
runpy.run_module(module, run_name="__main__", alter_sys=True)
