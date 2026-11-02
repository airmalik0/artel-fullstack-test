# Проверка состояния на самой цели: только чтение, ничего не правит.
check user_deploy id "$DEPLOY_USER"
check sshd_root_off bash -c 'sshd -T | grep -q "^permitrootlogin no"'
check sshd_password_off bash -c 'sshd -T | grep -q "^passwordauthentication no"'
check ufw_active bash -c 'ufw status | grep -q "^Status: active"'
check ufw_deny_in bash -c 'ufw status verbose | grep -q "deny (incoming)"'
check ufw_22 bash -c 'ufw status | grep -qE "^22/tcp[[:space:]]+ALLOW"'
check ufw_443_tcp bash -c 'ufw status | grep -qE "^443/tcp[[:space:]]+ALLOW"'
check ufw_443_udp bash -c 'ufw status | grep -qE "^443/udp[[:space:]]+ALLOW"'
check ufw_alt_tcp bash -c "ufw status | grep -qE '^$REALITY_ALT_PORT/tcp[[:space:]]+ALLOW'"
check bbr bash -c '[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]'
check fq bash -c '[ "$(sysctl -n net.core.default_qdisc)" = fq ]'
check auto_upgrades systemctl is-enabled --quiet unattended-upgrades
check xray_active systemctl is-active --quiet xray
check xray_enabled systemctl is-enabled --quiet xray
check hysteria_active systemctl is-active --quiet hysteria
check hysteria_enabled systemctl is-enabled --quiet hysteria
check tcp443_is_xray bash -c '[ "$(ss -H -ltnp "sport = :443" | grep -c "\"xray\"")" -ge 1 ]'
check tcp_alt_is_xray bash -c "[ \"\$(ss -H -ltnp 'sport = :$REALITY_ALT_PORT' | grep -c '\"xray\"')\" -ge 1 ]"
check udp443_is_hysteria bash -c '[ "$(ss -H -lunp "sport = :443" | grep -c "\"hysteria\"")" -ge 1 ]'
check xray_config_valid bash -c "su -s /bin/sh xray -c '/usr/local/bin/xray run -test -c /etc/xray/config.json'"
check hysteria_obfs grep -q 'type: salamander' /etc/hysteria/config.yaml
check reality_server_names python3 -I -c 'import json; c = json.load(open("/etc/xray/config.json")); raise SystemExit(0 if len(c["inbounds"]) == 2 and all(len(i["streamSettings"]["realitySettings"]["serverNames"]) >= 2 for i in c["inbounds"]) else 1)'
check secrets_private bash -c '[ "$(stat -c %a /etc/xray/reality.env)" = 640 ] && [ "$(stat -c %a /etc/hysteria/auth.env)" = 640 ]'
# Наружу открыты только 22/tcp, 443/tcp, порт второго Reality и 443/udp.
exposed="$(ss -H -tuln | awk '{print $1"/"$5}' | grep -vE '127\.0\.0\.|\[::1\]|%lo' | sed 's/\[::\]:/:/; s/0\.0\.0\.0:/:/; s/\*:/:/' | sort -u | paste -sd' ' -)"
fact exposed "$exposed"
check only_expected_ports bash -c "! printf '%s\n' $exposed | grep -vE '^(tcp/:22|tcp/:443|tcp/:$REALITY_ALT_PORT|udp/:443)$' | grep -q ."
finish
