#!/usr/bin/env bash
# Принудительная команда из authorized_keys. Аргументы задаёт ключ, а не клиент:
# SSH_ORIGINAL_COMMAND игнорируется, любая команда клиента приводит сюда же.
set -euo pipefail

AGENT_DIR=/home/agent/part3-agent
SOCKET=agent
SESSION=agent

# Терминала клиента может не быть в terminfo сервера, тогда tmux не стартует.
infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color

case "${1:-ro}" in
  rw)
    # Подключиться к живой сессии или поднять её. После выхода из агента остаётся
    # шелл, чтобы сессия не умирала вместе с ним.
    exec tmux -L "$SOCKET" new-session -A -s "$SESSION" -c "$AGENT_DIR" \
      "./start.sh; exec bash -l"
    ;;
  ro)
    tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null || {
      echo "сессия агента не запущена"
      exit 1
    }
    exec tmux -L "$SOCKET" attach-session -r -t "$SESSION"
    ;;
  *)
    exit 2
    ;;
esac
