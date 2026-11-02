#!/usr/bin/env bash
# Настройка своего дроплета под проверки check-host: HTTPS с настоящим сертификатом и HTTP. На UDP/51820 слушателя нет, на UDP/443 слушает Caddy (HTTP/3).
set -euo pipefail
IP=$1; H="${IP//./-}.sslip.io"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq; apt-get install -y -qq caddy tcpdump python3 >/dev/null
mkdir -p /srv/www; head -c 1048576 /dev/urandom > /srv/www/big; echo ok > /srv/www/small
cat > /etc/caddy/Caddyfile <<C
$H {
  root * /srv/www
  file_server
}
http://$IP {
  root * /srv/www
  file_server
}
C
systemctl restart caddy
sleep 12; curl -s -o /dev/null -w '%{http_code} %{size_download}\n' https://$H/big || true
