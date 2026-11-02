# Claude Code на моделях DeepSeek и развёртывание VPN-узла

Папка агента. Одна команда поднимает Claude Code, который вместо моделей Anthropic работает на
DeepSeek. Команда `/deploy-server <host>` ведёт пайплайн: с чистого сервера до рабочего выходного
узла VPN. Основной транспорт Xray VLESS+Reality на TCP/443, запасной Hysteria2 на UDP/443.
Удалённый доступ к живой сессии через tmux, отдельный ключ только на просмотр.

Детерминированную работу делают скрипты, агент выбирает шаг, читает JSON результата и разбирает
сбои. Успех определяет `scripts/verdict.sh`, а не текст модели. Всё ниже я прогнал на двух свежих
дроплетах DigitalOcean: хост агента и чистая цель.

## Что где лежит

```
start.sh                запуск Claude Code на DeepSeek
deploy.sh               развёртывание без человека, код возврата из verdict.json
build-archive.sh        сборка архива без секретов
CLAUDE.md               правила агента
.env.example            шаблон настроек
.claude/settings.json   env, разрешения, песочница, хуки
.claude/commands/       /deploy-server
.claude/agents/         recon, deployer, verifier, troubleshooter
.claude/hooks/          guard.py (запреты), verdict_gate.py (нельзя закончить без проверки)
scripts/                шаги развёртывания, verdict, диагностика
scripts/remote/         то, что выполняется на цели
tools/                  установка хоста, ключи, tmux, намеренные сбои, проба обхода, wire-tap
evidence/               выдержки логов живых прогонов, без секретов и адресов
```

## Как запустить

Нужен Linux-хост под агента и чистый сервер Ubuntu 22.04/24.04 или Debian 12/13 под узел. На хосте
агента под root (ставит tmux, bubblewrap, socat и Claude Code официальным установщиком):

```
sudo tools/bootstrap-agent-host.sh
```

Дальше под пользователем `agent` в этой папке:

```
cp .env.example .env          # вписать DEEPSEEK_API_KEY
tools/new-target-key.sh       # печатает публичный ключ, положить в authorized_keys root на цели
./start.sh                    # интерактивная сессия на DeepSeek
```

Внутри сессии `/deploy-server <host>`. Без человека: `./deploy.sh <host>`, код возврата берётся из
`output/<host>/verdict.json`. Клиентские конфиги появятся в `output/<host>/client/`: `xray-client.json`,
`hysteria-client.yaml`, `links.txt`. Это секреты, в git и архив они не идут, агенту не показываются.

Доступ к живой сессии. Два ключа создаю у себя в `secrets/` (`operator_ed25519`, `viewer_ed25519`),
публичные части копирую на хост и там под root:

```
sudo tools/tmux-access-setup.sh operator_ed25519.pub viewer_ed25519.pub
```

Подключение одной командой: `tools/attach.sh agent@<хост>` или только просмотр
`tools/attach.sh agent@<хост> ro`. Отключиться, не трогая сессию: `Ctrl-b`, затем `d`.

## Какие настройки реально работают

Подбирал по документации DeepSeek и Claude Code, потом каждую проверял прогоном: смотрел запрос
на проводе через `tools/wire-tap.py` и SNI соединений через tcpdump.

| Настройка | Значение | Что показал прогон |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | обязательна, путь `/v1/messages` Claude Code добавляет сам |
| `apiKeyHelper` | чтение файла с токеном | работает вместо `ANTHROPIC_AUTH_TOKEN`, токена нет в окружении claude и его подпроцессов |
| `ANTHROPIC_MODEL` | `deepseek-flash[1m]` | обязательна: без неё уходит `claude-opus-5-5`, DeepSeek молча подставляет дорогую v4-pro. Суффикс `[1m]` на провод не идёт, только задаёт окно контекста |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `deepseek-v4-pro[1m]` | `model: opus` у подагента даёт v4-pro |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `deepseek-flash[1m]` | `model: sonnet` у подагента даёт flash |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-flash` | `model: haiku` у подагента даёт flash |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | главная: без неё два соединения с `api.anthropic.com` за запуск, с ней ни одного. `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` и `DISABLE_AUTOUPDATER` вместе оставляют одно, поэтому их убрал |
| `skipWebFetchPreflight` | `true` | без неё WebFetch ходит на `api.anthropic.com` даже при отключённом трафике |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | убирает из системного промпта блок с версией и отпечатком клиента |
| `API_TIMEOUT_MS` | `600000` | действует: при 3000 на молчащем сервере запрос оборвался за 4,2 с |
| `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR` | `1` | bash возвращается в корень после каждой команды |

Проверил и не использую:

| Настройка | Что показал прогон |
|---|---|
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | на Linux сажает в песочницу все команды, шаги с ключами и сетью перестают работать. Вместо неё токен вынесен в `apiKeyHelper` |
| `CLAUDE_CODE_EFFORT_LEVEL` | действует, доходит до `output_config.effort`. DeepSeek советует `max`, оставил умолчание `high` |
| `MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_DISABLE_THINKING=1` | действуют, `thinking` исчезает из запроса. Не нужны |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | не нужна: DeepSeek принимает все заголовки beta, ответ 200. С ней инструментов в запросе 21 вместо 12 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | действует, но перекрыла бы роли подагентов |

<!-- CHECK -->

<!-- PROVEN -->

<!-- LIMITS -->
