#!/usr/bin/env bash
# Готовит чистый Ubuntu/Debian под хост агента: пользователь, пакеты, Claude Code.
# Запускать под root на самом хосте. Повторный запуск ничего не ломает.
#   sudo tools/bootstrap-agent-host.sh
set -euo pipefail

AGENT_USER="${AGENT_USER:-agent}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.316}"

[ "$(id -u)" -eq 0 ] || { echo "нужен root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
# Первые минуты после загрузки списки держат cloud-init и apt-daily.
for try in 1 2 3 4 5 6 7 8 9 10 11 12 0; do
  apt-get -o DPkg::Lock::Timeout=300 update -qq && break
  [ "$try" != 0 ] || exit 1
  sleep 10
done
apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends \
  tmux jq curl git rsync openssh-client ca-certificates python3 bubblewrap socat >/dev/null

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
  # Пароля нет и не будет: вход только по ключу.
  usermod -p '*' "$AGENT_USER"
fi

# Ubuntu 24.04 по умолчанию не даёт bwrap создавать пространства имён, без этого
# песочница и очистка окружения подпроцессов не стартуют.
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ] \
  && [ ! -f /etc/apparmor.d/bwrap ]; then
  cat >/etc/apparmor.d/bwrap <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
APPARMOR
  systemctl reload apparmor
fi

# Официальный установщик ставит бинарь в домашний каталог пользователя.
if ! sudo -iu "$AGENT_USER" bash -c '"$HOME/.local/bin/claude" --version' 2>/dev/null \
  | grep -q "^${CLAUDE_CODE_VERSION}"; then
  sudo -iu "$AGENT_USER" bash -c \
    "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION}"
fi

sudo -iu "$AGENT_USER" bash -c '"$HOME/.local/bin/claude" --version'
