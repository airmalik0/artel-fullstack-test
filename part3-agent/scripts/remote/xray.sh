# Xray VLESS + Reality на TCP/443.
ensure_pkgs unzip openssl ca-certificates
ensure_group_user xray

holder="$(port_holder tcp 443)"
if [ -n "$holder" ] && [ "$holder" != xray ]; then
  fact port_holder "$holder"
  die "port_busy tcp/443: $holder"
fi

arch="$(arch_suffix)"
if [ "$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print "v"$2}')" != "$XRAY_VERSION" ]; then
  [ "$arch" = amd64 ] && { asset=Xray-linux-64.zip; want="$XRAY_SHA256_AMD64"; }
  [ "$arch" = arm64 ] && { asset=Xray-linux-arm64-v8a.zip; want="$XRAY_SHA256_ARM64"; }
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$asset" \
    || die "не скачан Xray $XRAY_VERSION"
  [ "$(sha256sum "$tmp/x.zip" | cut -d' ' -f1)" = "$want" ] || die "контрольная сумма Xray не сошлась"
  unzip -qo "$tmp/x.zip" xray -d "$tmp"
  install -m 755 "$tmp/xray" /usr/local/bin/xray
  rm -rf "$tmp"
  changed "xray $XRAY_VERSION"
  restart=1
fi

# Ключи создаются один раз: иначе каждый запуск ломал бы клиентов.
SECRETS=/etc/xray/reality.env
install -d -m 750 -o root -g xray /etc/xray
if [ ! -s "$SECRETS" ]; then
  pair="$(/usr/local/bin/xray x25519)"
  priv="$(printf '%s\n' "$pair" | awk -F': *' 'NR==1{print $2}')"
  pub="$(printf '%s\n' "$pair" | awk -F': *' 'NR==2{print $2}')"
  [ -n "$priv" ] && [ -n "$pub" ] || die "xray x25519 вернул неожиданный вывод"
  umask 027
  {
    echo "PRIVATE_KEY=$priv"
    echo "PUBLIC_KEY=$pub"
    echo "UUID=$(/usr/local/bin/xray uuid)"
    echo "SHORT_ID=$(openssl rand -hex 8)"
  } >"$SECRETS"
  umask 077
  chown root:xray "$SECRETS"
  chmod 640 "$SECRETS"
  changed "ключи Reality созданы"
fi
# shellcheck disable=SC1090
. "$SECRETS"

restart="${restart:-0}"
python3 - "$PRIVATE_KEY" "$UUID" "$SHORT_ID" "$REALITY_SNI" <<'PY' | ensure_file /etc/xray/config.json 640 root:xray && restart=1
import json, sys
key, uuid, sid, sni = sys.argv[1:5]
print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0", "port": 443, "protocol": "vless",
        "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
        "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
            "show": False, "target": f"{sni}:443", "xver": 0,
            "serverNames": [sni], "privateKey": key, "shortIds": [sid]}},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
    # Узел не должен быть мостом во внутреннюю сеть хостинга.
    "routing": {"rules": [{"type": "field", "outboundTag": "block", "ip": [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
        "169.254.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10", "::1/128"]}]},
}, indent=2, sort_keys=True))
PY

ensure_file /etc/systemd/system/xray.service 644 root:root <<'UNIT' && restart=1
[Unit]
Description=Xray VLESS Reality
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

su -s /bin/sh xray -c '/usr/local/bin/xray run -test -c /etc/xray/config.json' >/dev/null 2>&1 \
  || die "xray отверг конфиг"
ensure_service xray "$restart"
ensure_ufw_allow 443/tcp

check xray_active systemctl is-active --quiet xray
check xray_enabled systemctl is-enabled --quiet xray
check tcp443_is_xray bash -c '[ "$(ss -H -ltnp "sport = :443" | grep -c "\"xray\"")" -ge 1 ]'
check ufw_443_tcp bash -c 'ufw status | grep -qE "^443/tcp[[:space:]]+ALLOW"'
# Reality отдаёт на чужой запрос настоящий сертификат сайта-прикрытия.
check reality_decoy bash -c "timeout 15 openssl s_client -connect 127.0.0.1:443 -servername '$REALITY_SNI' -tls1_3 </dev/null 2>/dev/null | grep -q 'Verification: OK\|Verify return code: 0'"
fact xray_version "$(/usr/local/bin/xray version | awk 'NR==1{print $2}')"
finish
