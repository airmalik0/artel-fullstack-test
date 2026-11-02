# Стенд повторяет ограничения сервера: без сети (--network none), PID 1 без супервизора,
# вход только снаружи. Зависимости ставятся при сборке: в работающем контейнере сети нет.
FROM python:3.12-slim
RUN pip install --no-cache-dir python-telegram-bot==21.11.1 httpx==0.28.1 \
 && apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/* \
 && useradd -u 10001 -M -s /usr/sbin/nologin bot
COPY demo_bot.py /opt/bots/demo/demo_bot.py
COPY demo-backup.sh /usr/local/sbin/demo-backup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh /usr/local/sbin/demo-backup.sh \
 && mkdir -p /opt/bots/demo/data /var/log/demo && chown 10001:10001 /opt/bots/demo/data /var/log/demo
ENTRYPOINT ["/entrypoint.sh"]
