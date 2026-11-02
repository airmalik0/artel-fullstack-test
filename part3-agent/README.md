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

<!-- RUN -->

<!-- ENV -->

<!-- CHECK -->

<!-- PROVEN -->

<!-- LIMITS -->
