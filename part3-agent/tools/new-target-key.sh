#!/usr/bin/env bash
# Отдельный ключ для входа на целевые серверы. Публичную часть положи на цель в
# authorized_keys того пользователя, что указан в TARGET_SSH_USER.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
mkdir -p "$ROOT/secrets"
KEY="$ROOT/secrets/target_ed25519"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C artel-agent -f "$KEY"
cat "$KEY.pub"
