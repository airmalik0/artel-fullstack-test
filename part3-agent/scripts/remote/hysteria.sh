# Hysteria2 на UDP/443 с самоподписанным сертификатом и привязкой отпечатка у клиента.
ensure_pkgs openssl ca-certificates
ensure_group_user hysteria

holder="$(port_holder udp 443)"
if [ -n "$holder" ] && [ "$holder" != hysteria ]; then
  fact port_holder "$holder"
  die "port_busy udp/443: $holder"
fi

restart=0
arch="$(arch_suffix)"
if [ "$(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/{print $2}')" != "$HYSTERIA_VERSION" ]; then
  [ "$arch" = amd64 ] && want="$HYSTERIA_SHA256_AMD64"
  [ "$arch" = arm64 ] && want="$HYSTERIA_SHA256_ARM64"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/h" "https://github.com/apernet/hysteria/releases/download/app/$HYSTERIA_VERSION/hysteria-linux-$arch" \
    || die "не скачан Hysteria $HYSTERIA_VERSION"
  [ "$(sha256sum "$tmp/h" | cut -d' ' -f1)" = "$want" ] || die "контрольная сумма Hysteria не сошлась"
  install -m 755 "$tmp/h" /usr/local/bin/hysteria
  rm -rf "$tmp"
  changed "hysteria $HYSTERIA_VERSION"
  restart=1
fi

install -d -m 750 -o root -g hysteria /etc/hysteria
SECRETS=/etc/hysteria/auth.env
if [ ! -s "$SECRETS" ]; then
  ( umask 027; echo "PASSWORD=$(openssl rand -hex 24)" >"$SECRETS" )
  chown root:hysteria "$SECRETS"
  chmod 640 "$SECRETS"
  changed "пароль Hysteria создан"
fi
if [ ! -s /etc/hysteria/server.key ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=$REALITY_SNI" >/dev/null 2>&1 || die "сертификат не создан"
  chown root:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
  chmod 640 /etc/hysteria/server.key
  chmod 644 /etc/hysteria/server.crt
  changed "сертификат Hysteria создан"
  restart=1
fi
# shellcheck disable=SC1090
. "$SECRETS"

ensure_file /etc/hysteria/config.yaml 640 root:hysteria <<CONF && restart=1
listen: :443
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://$REALITY_SNI/
    rewriteHost: true
acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(100.64.0.0/10)
    - direct(all)
CONF

ensure_file /etc/systemd/system/hysteria.service 644 root:root <<'UNIT' && restart=1
[Unit]
Description=Hysteria2
After=network-online.target
Wants=network-online.target

[Service]
User=hysteria
Group=hysteria
Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

ensure_service hysteria "$restart"
ensure_ufw_allow 443/udp

check hysteria_active systemctl is-active --quiet hysteria
check hysteria_enabled systemctl is-enabled --quiet hysteria
check udp443_is_hysteria bash -c '[ "$(ss -H -lunp "sport = :443" | grep -c "\"hysteria\"")" -ge 1 ]'
check ufw_443_udp bash -c 'ufw status | grep -qE "^443/udp[[:space:]]+ALLOW"'
fact hysteria_version "$(/usr/local/bin/hysteria version | awk '/^Version:/{print $2}')"
finish
