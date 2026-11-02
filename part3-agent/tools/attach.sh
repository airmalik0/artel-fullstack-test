#!/usr/bin/env bash
# Подключиться к сессии агента одной командой:
#   tools/attach.sh agent@<хост>        оператор
#   tools/attach.sh agent@<хост> ro     только просмотр
# Отключиться, не трогая сессию: Ctrl-b, затем d.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?использование: tools/attach.sh agent@<хост> [rw|ro]}"
case "${2:-rw}" in
  rw) KEY="$ROOT/secrets/operator_ed25519" ;;
  ro) KEY="$ROOT/secrets/viewer_ed25519" ;;
  *) echo "режим: rw или ro" >&2; exit 2 ;;
esac
exec ssh -F /dev/null -tt -i "$KEY" -o IdentitiesOnly=yes -o ServerAliveInterval=15 "$TARGET"
