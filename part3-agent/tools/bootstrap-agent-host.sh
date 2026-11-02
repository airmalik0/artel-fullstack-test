#!/usr/bin/env bash
# Готовит чистый Ubuntu/Debian под хост агента: пользователь, пакеты, Claude Code.
# Запускать под root на самом хосте. Повторный запуск ничего не ломает.
#   sudo tools/bootstrap-agent-host.sh
set -euo pipefail

AGENT_USER="${AGENT_USER:-agent}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.316}"

[ "$(id -u)" -eq 0 ] || { echo "нужен root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends \
  tmux jq curl git rsync openssh-client ca-certificates python3 bubblewrap >/dev/null

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
  # Пароля нет и не будет: вход только по ключу.
  usermod -p '*' "$AGENT_USER"
fi

# Официальный установщик ставит бинарь в домашний каталог пользователя.
if ! sudo -iu "$AGENT_USER" bash -c '"$HOME/.local/bin/claude" --version' 2>/dev/null \
  | grep -q "^${CLAUDE_CODE_VERSION}"; then
  sudo -iu "$AGENT_USER" bash -c \
    "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION}"
fi

sudo -iu "$AGENT_USER" bash -c '"$HOME/.local/bin/claude" --version'
