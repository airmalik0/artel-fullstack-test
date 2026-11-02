# Контейнер формы сервера для профиля real. Бот, лаунчер и entrypoint написаны мной заново,
# совпадают только пути, права и версии из снимка: .env 640 root:10001, python-dotenv 1.2.4.
# Собирается из каталога repro/: docker build -f stand/real/Dockerfile .
FROM python:3.12-slim
RUN pip install --no-cache-dir python-telegram-bot==21.11.1 httpx==0.28.1 python-dotenv==1.2.4 \
 && apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/* \
 && useradd -u 10001 -M -s /usr/sbin/nologin bot
COPY stand/real/amigo_main.py /opt/bots/amigo/amigo/main.py
COPY stand/real/run_prod.py /opt/bots/amigo/run_prod.py
COPY stand/real/amigo-backup.sh /usr/local/sbin/amigo-backup.sh
COPY stand/real/entrypoint.sh /entrypoint.sh
COPY stand/real/bystander.py /opt/amigo-demo/run_demo_bot.py
COPY fix/relay.py /opt/amigo-demo/ssh_api_relay.py
RUN chmod 755 /entrypoint.sh /usr/local/sbin/amigo-backup.sh /opt/bots/amigo/run_prod.py \
 && touch /opt/bots/amigo/amigo/__init__.py \
 && mkdir -p /opt/bots/amigo/data /var/log/amigo && chown 10001:10001 /opt/bots/amigo/data /var/log/amigo
ENTRYPOINT ["/entrypoint.sh"]
