#!/usr/bin/env bash
# Удалённый доступ к сессии агента через tmux. Запускать под root на хосте агента:
#   sudo tools/tmux-access-setup.sh <operator.pub> <viewer.pub>
# Два ключа одного пользователя, у каждого своя принудительная команда: оператор
# работает в сессии, наблюдатель только смотрит. Шелла, форвардинга и scp нет ни у кого.
set -euo pipefail

AGENT_USER="${AGENT_USER:-agent}"
OPERATOR_PUB="${1:?нужен публичный ключ оператора}"
VIEWER_PUB="${2:?нужен публичный ключ наблюдателя}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$HERE/.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "нужен root" >&2; exit 1; }
id "$AGENT_USER" >/dev/null || { echo "нет пользователя $AGENT_USER" >&2; exit 1; }
command -v tmux >/dev/null || { echo "нет tmux" >&2; exit 1; }

# Вход только по ключу: пароль заблокирован, sshd его не спросит.
usermod -p '*' "$AGENT_USER"
cat >/etc/ssh/sshd_config.d/10-agent-session.conf <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
Match User $AGENT_USER
    AuthenticationMethods publickey
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
CONF
sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd

install -m 755 "$HERE/agent-session.sh" /usr/local/bin/agent-session
sed -i "s|^AGENT_DIR=.*|AGENT_DIR=$AGENT_DIR|" /usr/local/bin/agent-session

HOME_DIR="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "$HOME_DIR/.ssh"
{
  printf 'restrict,pty,command="/usr/local/bin/agent-session rw" %s\n' "$(cat "$OPERATOR_PUB")"
  printf 'restrict,pty,command="/usr/local/bin/agent-session ro" %s\n' "$(cat "$VIEWER_PUB")"
} >"$HOME_DIR/.ssh/authorized_keys"
chown "$AGENT_USER:$AGENT_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

# Сессия не должна зависеть от входа по ssh.
loginctl enable-linger "$AGENT_USER"
echo "готово: tools/attach.sh $AGENT_USER@<хост> rw|ro"
