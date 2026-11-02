#!/usr/bin/env bash
# Собирает artel-agent.tar.gz из папки агента. Секреты, журналы сессий и результаты
# прогонов в архив не идут, а готовый архив проверяется на запрещённые имена.
#   ./build-archive.sh [куда положить архив]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$ROOT/dist}"
mkdir -p "$DEST"
OUT="$(cd "$DEST" && pwd)/artel-agent.tar.gz"

# Тар macOS иначе кладёт служебные файлы ._* с расширенными атрибутами.
export COPYFILE_DISABLE=1
tar -C "$(dirname "$ROOT")" -czf "$OUT" \
  --exclude='.env' --exclude='.env.*' --exclude='.agent-home' --exclude='.cache' \
  --exclude='output' --exclude='secrets' --exclude='dist' \
  --exclude='*.tar.gz' --exclude='*.log' --exclude='*.pem' --exclude='*.key' \
  --exclude='*.token' --exclude='*_ed25519' --exclude='*_ed25519.pub' \
  --exclude='.git' --exclude='__pycache__' --exclude='.DS_Store' \
  --exclude='.claude/settings.local.json' \
  --exclude='node_modules' --exclude='package.json' --exclude='package-lock.json' \
  --exclude='pnpm-lock.yaml' --exclude='yarn.lock' --exclude='bunfig.toml' \
  "$(basename "$ROOT")"

# .env.example исключён маской .env.*, добавляем его отдельно.
UNPACK="$(mktemp -d)"
trap 'rm -rf "${UNPACK:?}"' EXIT
tar -C "$UNPACK" -xzf "$OUT"
cp "$ROOT/.env.example" "$UNPACK/$(basename "$ROOT")/.env.example"
tar -C "$UNPACK" -czf "$OUT" "$(basename "$ROOT")"

LIST="$(tar -tzf "$OUT")"
if printf '%s\n' "$LIST" | grep -E '(^|/)(\.env$|\.env\.[^e]|\.agent-home|secrets/|output/|\.cache/|[^/]*\.token$|[^/]*_ed25519)'; then
  echo "в архив попало запрещённое, сборка отменена" >&2
  rm -f "$OUT"
  exit 1
fi
printf 'архив: %s\nфайлов: %s, размер: %s байт\n' "$OUT" "$(printf '%s\n' "$LIST" | grep -vc '/$')" "$(wc -c <"$OUT" | tr -d ' ')"
