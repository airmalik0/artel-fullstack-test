#!/bin/bash
# Форма /entrypoint.sh сервера: маркеров bot-start нет, бот отсюда не запускается.
# Приманка это настоящий python3 с подписью бота: /proc/PID/exe у неё тоже python.
# PID 1 это sleep с подписью systemd.
PY(){ (exec -a "$1" python3 -c "import time; time.sleep(3600)") & }
PY "python3 -m amigo.main"

exec -a "/lib/systemd/systemd --system --deserialize 31" sleep infinity
