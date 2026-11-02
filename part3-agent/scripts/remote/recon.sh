# Разведка: только чтение. Отказ, если цель не подходит.
. /etc/os-release
fact os "$ID $VERSION_ID"
fact kernel "$(uname -r)"
fact arch "$(uname -m)"
fact mem_mb "$(free -m | awk '/^Mem:/{print $2}')"
fact disk_free_gb "$(df -BG --output=avail / | tail -1 | tr -dc 0-9)"
fact login_user "$(logname 2>/dev/null || echo unknown)"
fact tcp443 "$(port_holder tcp 443)"
fact udp443 "$(port_holder udp 443)"
fact ufw "$(ufw status 2>/dev/null | head -1 | awk '{print $2}')"
fact congestion "$(sysctl -n net.ipv4.tcp_congestion_control)"
fact root_login "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
fact password_auth "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
fact xray_version "$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')"
fact hysteria_version "$(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/{print $2}')"

case "$ID:$VERSION_ID" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die "система не поддерживается: $ID $VERSION_ID" ;;
esac
arch_suffix >/dev/null
[ "$(free -m | awk '/^Mem:/{print $2}')" -ge 450 ] || die "мало памяти"
check python3 command -v python3
check has_systemd systemctl --version
check disk_1gb test "$(df -BG --output=avail / | tail -1 | tr -dc 0-9)" -ge 1
check sni_tls13 bash -c "timeout 15 openssl s_client -connect '$REALITY_SNI:443' -servername '$REALITY_SNI' -tls1_3 -alpn h2 </dev/null 2>/dev/null | grep -qE 'TLSv1.3' "
finish
