#!/bin/bash
# Состояние «до»: как на сервере. Бот запущен один раз фоном, PID 1 это sleep.
# Упавший бот никто не поднимет, зомби никто не соберёт.
# bot-start
(
  cd /opt/bots/demo
  [ -f .env ] && set -a && . ./.env && set +a
  exec setpriv --reuid=10001 --regid=10001 --clear-groups \
    python3 -u demo_bot.py >>/var/log/demo/bot.log 2>&1
) &
# bot-end

exec sleep infinity
