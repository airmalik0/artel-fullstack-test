#!/usr/bin/env bash
# Поднимает Claude Code на моделях DeepSeek. Все аргументы уходят в claude:
#   ./start.sh                         интерактивная сессия
#   ./start.sh -p "вопрос"             разовый запрос
# Настройки и история живут в .agent-home, домашний ~/.claude не читается.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
REAL_HOME="$HOME"

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$REAL_HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || { echo "claude не найден: tools/bootstrap-agent-host.sh" >&2; exit 1; }

# Токен: из окружения или одной строкой из .env. Файл не исполняется и
# остальные его значения в окружение не попадают.
TOKEN="${DEEPSEEK_API_KEY:-}"
if [ -z "$TOKEN" ] && [ -f .env ]; then
  TOKEN="$(sed -n 's/^DEEPSEEK_API_KEY=//p' .env | tail -1)"
fi
[ -n "$TOKEN" ] || { echo "нет токена: заполни DEEPSEEK_API_KEY в .env" >&2; exit 1; }

# Ключи Anthropic из окружения владельца не должны перебить DeepSeek.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN DEEPSEEK_API_KEY
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
# Подпроцессы агента не должны знать сокеты вокруг сессии: tmux, ssh-agent, dbus.
unset TMUX TMUX_PANE SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS

# WIRE_TAP_PORT включает просмотр запросов через tools/wire-tap.py.
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
[ -z "${WIRE_TAP_PORT:-}" ] || ANTHROPIC_BASE_URL="http://127.0.0.1:$WIRE_TAP_PORT"

# Эти переменные должны действовать с первой секунды, до чтения settings.json.
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ATTRIBUTION_HEADER=0

# Изоляция: свой каталог настроек и свой HOME.
AGENT_HOME="$ROOT/.agent-home"
export CLAUDE_CONFIG_DIR="$AGENT_HOME"
export HOME="$AGENT_HOME/home"
mkdir -p "$HOME" "$ROOT/.cache" "$ROOT/output" "$ROOT/secrets"
chmod 700 "$AGENT_HOME"

# Токена нет в окружении claude, значит его нет и у bash агента. Claude Code берёт
# его из файла через apiKeyHelper. CLAUDE_CODE_SUBPROCESS_ENV_SCRUB здесь не подходит:
# на Linux он загоняет в песочницу все команды, а шаги развёртывания живут вне неё.
TOKEN_FILE="$AGENT_HOME/api-token"
( umask 077; printf '%s\n' "$TOKEN" >"$TOKEN_FILE" )
unset TOKEN

# Первый запуск без мастера и без вопроса о доверии папке.
python3 -I - "$AGENT_HOME/.claude.json" "$ROOT" <<'PY'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
state = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
state["hasCompletedOnboarding"] = True
state.setdefault("projects", {}).setdefault(root, {})["hasTrustDialogAccepted"] = True
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh)
os.chmod(path, 0o600)
PY

# Песочнице bash запрещаем домашний каталог владельца целиком. Путь известен
# только здесь, поэтому правило собирается при запуске. Если сама папка агента
# лежит в домашнем каталоге, она открывается обратно, секреты внутри неё закрыты
# в settings.json.
RUNTIME_SETTINGS="$(python3 -I - "$REAL_HOME" "$ROOT" "$TOKEN_FILE" <<'PY'
import json, os, shlex, sys
home, root, token_file = sys.argv[1:4]
settings = {
    "apiKeyHelper": "cat " + shlex.quote(token_file),
    # Bash агента не пишет ни во что, что уже лежит в папке, иначе он подменил бы скрипт
    # из excludedCommands. Корень целиком закрыть нельзя: туда песочница кладёт пустые
    # точки монтирования. Новые файлы в корне безвредны: скрипты не берут их из cwd.
    "sandbox": {"filesystem": {
        "denyRead": [home],
        "allowRead": [root],
        "denyWrite": sorted(os.path.join(root, name) for name in set(os.listdir(root)) | {
            ".env", ".cache", ".agent-home", "output", "secrets", "CLAUDE.local.md"}),
    }},
}
settings.update(json.loads(os.environ.get("AGENT_EXTRA_SETTINGS") or "{}"))
print(json.dumps(settings))
PY
)"

exec "$CLAUDE_BIN" --settings "$RUNTIME_SETTINGS" "$@"
