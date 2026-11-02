# Помощники шага на целевом сервере. Каждое изменение считается: changed пуст,
# значит повторный запуск ничего не тронул. Проверки идут после изменений.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
_D="$(mktemp -d)"
: >"$_D/changes"; : >"$_D/checks"; : >"$_D/facts"; : >"$_D/reason"
APT=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold -y -qq --no-install-recommends)

log() { echo "[$STEP] $*" >&2; }
changed() { printf '%s\n' "$*" >>"$_D/changes"; log "изменено: $*"; }
fact() { printf '%s\t%s\n' "$1" "$2" >>"$_D/facts"; }

# check <id> <команда...>: результат идёт в JSON, вывод команды в журнал.
check() {
  local id="$1"
  shift
  if "$@" >>"$_D/check.log" 2>&1; then
    printf '%s\tok\n' "$id" >>"$_D/checks"
  else
    printf '%s\tfail\n' "$id" >>"$_D/checks"
    log "проверка не прошла: $id"
  fi
}

finish() {
  python3 -I - "$_D" "$STEP" <<'PY'
import json, sys
d, step = sys.argv[1], sys.argv[2]
read = lambda n: [l.rstrip("\n") for l in open(f"{d}/{n}", encoding="utf-8") if l.strip()]
checks = {a: b for a, b in (l.split("\t") for l in read("checks"))}
facts = {a: b for a, b in (l.split("\t", 1) for l in read("facts"))}
reason = " ".join(read("reason"))
ok = not reason and all(v == "ok" for v in checks.values())
if not reason and not ok:
    reason = "не прошли проверки: " + ", ".join(k for k, v in checks.items() if v != "ok")
print("::result::" + json.dumps({"step": step, "ok": ok, "changed": read("changes"),
                                 "checks": checks, "facts": facts, "reason": reason},
                                ensure_ascii=False))
PY
  rm -rf "$_D"
}

# Прервать шаг: reason уходит агенту как машинная причина.
die() {
  printf '%s\n' "$*" >>"$_D/reason"
  finish
  exit 1
}

# ensure_file <путь> <режим> <владелец:группа>; содержимое на stdin.
# Код 0, если файл изменён, 1 если совпал.
ensure_file() {
  local path="$1" mode="$2" owner="$3" tmp cur
  tmp="$(mktemp)"
  cat >"$tmp"
  cur="$(stat -c '%a %U:%G' "$path" 2>/dev/null || true)"
  if [ -f "$path" ] && cmp -s "$tmp" "$path" && [ "$cur" = "$mode $owner" ]; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp" "$path"
  rm -f "$tmp"
  changed "$path"
  return 0
}

ensure_pkgs() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed' || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  "${APT[@]}" update >/dev/null 2>&1
  "${APT[@]}" install "${missing[@]}" >/dev/null 2>&1 || die "apt не поставил: ${missing[*]}"
  changed "пакеты: ${missing[*]}"
}

ensure_group_user() {
  local user="$1"
  id "$user" >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --shell /usr/sbin/nologin "$user" || die "не создан пользователь $user"
  changed "пользователь $user"
}

# Кто держит порт: пусто, если свободен.
port_holder() {
  local proto="$1" port="$2"
  if [ "$proto" = tcp ]; then
    ss -H -ltnp "sport = :$port" 2>/dev/null
  else
    ss -H -lunp "sport = :$port" 2>/dev/null
  fi | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | paste -sd, -
}

ensure_ufw_allow() {
  local rule="$1"
  ufw status 2>/dev/null | grep -qE "^${rule}[[:space:]]+ALLOW" && return 0
  ufw allow "$rule" >/dev/null || die "ufw не принял $rule"
  changed "ufw: разрешён $rule"
}

# Поднять службу и включить автозапуск. restart=1, если конфиг менялся.
ensure_service() {
  local unit="$1" restart="${2:-0}"
  if [ "$restart" = 1 ]; then
    systemctl daemon-reload
    systemctl restart "$unit" || true
    changed "$unit перезапущена"
  fi
  if ! systemctl is-enabled --quiet "$unit"; then
    systemctl enable "$unit" >/dev/null 2>&1
    changed "$unit: автозапуск"
  fi
  if ! systemctl is-active --quiet "$unit"; then
    systemctl reset-failed "$unit" 2>/dev/null || true
    systemctl start "$unit" || true
    changed "$unit запущена"
  fi
  sleep 1
}

arch_suffix() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "архитектура не поддерживается: $(uname -m)" ;;
  esac
}
