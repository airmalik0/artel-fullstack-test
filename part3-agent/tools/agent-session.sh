#!/usr/bin/env bash
# Принудительная команда из authorized_keys. Аргументы задаёт ключ, а не клиент:
# SSH_ORIGINAL_COMMAND игнорируется, любая команда клиента приводит сюда же.
set -euo pipefail

AGENT_DIR=/home/agent/part3-agent
# Сокет внутри .agent-home: этот каталог закрыт для песочницы на чтение и запись,
# иначе из неё команда tmux выполнилась бы уже вне песочницы.
SOCKET="$AGENT_DIR/.agent-home/tmux.sock"
SESSION=agent
mkdir -p "$AGENT_DIR/.agent-home"
chmod 700 "$AGENT_DIR/.agent-home"

# Терминала клиента может не быть в terminfo сервера, тогда tmux не стартует.
infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color

case "${1:-ro}" in
  rw)
    # Подключиться к живой сессии или поднять её. После выхода из агента остаётся
    # шелл, чтобы сессия не умирала вместе с ним.
    exec tmux -S "$SOCKET" new-session -A -s "$SESSION" -c "$AGENT_DIR" \
      "./start.sh; exec bash -l"
    ;;
  ro)
    tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null || {
      echo "сессия агента не запущена"
      exit 1
    }
    exec tmux -S "$SOCKET" attach-session -r -t "$SESSION"
    ;;
  *)
    exit 2
    ;;
esac
