#!/usr/bin/env python3
"""PreToolUse: не даёт агенту прочитать секреты и выйти из папки.

Токен, ключи и клиентские конфиги не должны попасть в контекст: всё, что видит
модель, уходит провайдеру. Это первая линия. Вторая, песочница bash, держит то,
что мимо шаблонов пройдёт (см. раздел про обход в README).
"""
import json
import os
import re
import sys

data = json.load(sys.stdin)
tool = data.get("tool_name", "")
args = data.get("tool_input") or {}
root = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ".")

SECRET_PATH = re.compile(
    r"(^|/)(\.env(\.[^/]*)?|\.agent-home|secrets|[^/]*\.token|[^/]*_ed25519|\.ssh)(/|$)"
)
CLIENT_PATH = re.compile(r"(^|/)output/[^/]+/client(/|$)")
WRITE_LOCKED = re.compile(r"^(\.claude|\.cache|scripts|tools|output)(/|$)|^(start|deploy|build-archive)\.sh$|^\.env|^CLAUDE")
STEP_CMD = re.compile(r"\./scripts/(step|diag|free-port|verdict)\.sh( [A-Za-z0-9._:-]+){0,3}")

# То, что нельзя писать в команде bash ни в каком виде.
BASH_DENY = [
    (r"\.env(?!\.example)\b", "файл .env"),
    (r"\.agent-home", "каталог настроек агента"),
    (r"\bsecrets\b", "каталог секретов"),
    (r"\.token\b", "файл токена"),
    (r"_ed25519", "приватный ключ"),
    (r"\.ssh\b", "каталог .ssh"),
    (r"output/[^\s/]*/client|output/\*", "клиентские конфиги"),
    (r"/proc/[^\s]*/(environ|mem|cmdline)", "окружение процессов"),
    (r"(^|[\s;|&(`])(env|printenv|export|declare|compgen|set)(\s*($|[|;&>)]))", "вывод окружения"),
    (r"(ANTHROPIC|DEEPSEEK)_[A-Z_]*(TOKEN|KEY)", "переменная с токеном"),
    (r"\.[^\s/'\"]*[*?\[][^\s/'\"]*", "маска по скрытым файлам"),
    (r"\b(base64|xxd|openssl\s+enc)\b.*-d\b.*\|\s*(ba|z|da)?sh\b", "декодирование в shell"),
    (r"\b(eval|source)\b", "выполнение произвольной строки"),
    (r"\b(tmux|screen|systemd-run|systemctl|dbus-send|busctl)\b", "сокеты вне песочницы"),
]


def deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": f"guard: {reason}",
                }
            },
            ensure_ascii=False,
        )
    )
    sys.exit(0)


def check_path(raw, writing=False):
    if not raw:
        return
    full = os.path.realpath(os.path.join(data.get("cwd") or root, os.path.expanduser(raw)))
    if full != root and not full.startswith(root + os.sep):
        deny(f"путь вне папки агента: {raw}")
    rel = os.path.relpath(full, root)
    if rel == ".env.example":
        return
    if SECRET_PATH.search(rel) or CLIENT_PATH.search(rel):
        deny(f"секреты недоступны агенту: {raw}")
    if writing and WRITE_LOCKED.search(rel):
        deny(f"папка агента защищена от правки: {raw}")


if tool in ("Bash", "Monitor"):
    command = str(args.get("command", ""))
    # Эти скрипты выполняются вне песочницы, поэтому форма запуска только одна: без
    # переменных впереди, цепочек и подстановок, и только из корня папки. Относительный
    # шаблон разрешения иначе сработал бы на чужой scripts/step.sh в другом каталоге.
    if "./scripts/" in command:
        if not STEP_CMD.fullmatch(command.strip()):
            deny("скрипты запускай ровно одной командой из корня папки, без ; && | и подстановок. Код возврата виден в результате вызова")
        if os.path.realpath(data.get("cwd") or root) != root:
            deny("скрипты запускаются только из корня папки агента")
    for pattern, what in BASH_DENY:
        if re.search(pattern, command):
            deny(f"команда затрагивает: {what}")
elif tool == "Read":
    check_path(args.get("file_path"))
elif tool in ("Edit", "Write", "NotebookEdit"):
    check_path(args.get("file_path") or args.get("notebook_path"), writing=True)
elif tool in ("Grep", "Glob"):
    check_path(args.get("path"))
    for key in ("pattern", "glob"):
        value = str(args.get(key) or "")
        if tool == "Glob" or key == "glob":
            if SECRET_PATH.search(value) or re.search(r"\.env|\.agent-home|secrets|client", value):
                deny(f"маска задевает секреты: {value}")
    # Grep по всей папке обходит запрет на чтение, если не исключить секреты явно.
    target = os.path.realpath(os.path.join(data.get("cwd") or root, args.get("path") or "."))
    if target == root and not args.get("glob"):
        deny("Grep по всей папке запрещён: укажи path (scripts, output/<host>/steps) или glob")

sys.exit(0)
