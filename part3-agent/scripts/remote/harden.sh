# Укрепление в две фазы. PHASE=user готовит вход, PHASE=lock закрывает root и
# пароли. Между ними step.sh проверяет новый вход извне, иначе можно потерять сервер.
if [ "$PHASE" = user ]; then
  ensure_pkgs ufw unattended-upgrades openssl curl sudo iproute2

  STAMP=/var/lib/artel-agent/last-upgrade
  if [ -z "$(find "$STAMP" -mmin -1440 2>/dev/null)" ]; then
    before="$(sha256sum /var/lib/dpkg/status)"
    # На свежем сервере первые минуты списки держат cloud-init и apt-daily, а Lock::Timeout
    # распространяется только на dpkg. Поэтому несколько попыток, а не отказ с первой.
    for try in 1 2 3 4 5 6 7 8 9 10 11 12 0; do
      "${APT[@]}" update >/dev/null 2>&1 && break
      [ "$try" != 0 ] || die "apt update не прошёл"
      sleep 10
    done
    "${APT[@]}" upgrade >/dev/null 2>&1 || die "apt upgrade не прошёл"
    [ "$before" = "$(sha256sum /var/lib/dpkg/status)" ] || changed "обновления установлены"
    mkdir -p "${STAMP%/*}"
    date -Is >"$STAMP"
  fi

  if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$DEPLOY_USER" || die "не создан $DEPLOY_USER"
    usermod -p '*' "$DEPLOY_USER"
    changed "пользователь $DEPLOY_USER"
  fi
  printf '%s\n' "$PUBKEY" | ensure_file "/home/$DEPLOY_USER/.ssh/authorized_keys" 600 "$DEPLOY_USER:$DEPLOY_USER" || true
  chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  chmod 700 "/home/$DEPLOY_USER/.ssh"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEPLOY_USER" | ensure_file "/etc/sudoers.d/90-$DEPLOY_USER" 440 root:root || true
  visudo -cf "/etc/sudoers.d/90-$DEPLOY_USER" >/dev/null || die "sudoers не прошёл проверку"

  ensure_file /etc/sysctl.d/90-vpn-node.conf 644 root:root <<'CONF' && sysctl --system >/dev/null
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
CONF

  ensure_file /etc/apt/apt.conf.d/20auto-upgrades 644 root:root <<'CONF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
  systemctl is-enabled --quiet unattended-upgrades || { systemctl enable --now unattended-upgrades >/dev/null 2>&1; changed "unattended-upgrades: включён"; }

  ensure_ufw_allow 22/tcp
  if ! ufw status | grep -q '^Status: active'; then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null || die "ufw не включился"
    changed "ufw включён"
  fi

  check user_exists id "$DEPLOY_USER"
  check bbr_active bash -c '[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]'
  check fq_active bash -c '[ "$(sysctl -n net.core.default_qdisc)" = fq ]'
  check ufw_active bash -c 'ufw status | grep -q "^Status: active"'
  check ufw_default_deny bash -c 'ufw status verbose | grep -q "deny (incoming)"'
  check auto_upgrades_on systemctl is-enabled --quiet unattended-upgrades
else
  ensure_file /etc/ssh/sshd_config.d/10-hardening.conf 644 root:root <<CONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
AllowUsers $DEPLOY_USER
CONF
  rc=$?
  sshd -t || { rm -f /etc/ssh/sshd_config.d/10-hardening.conf; die "sshd отверг конфиг, файл снят"; }
  if [ "$rc" -eq 0 ]; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd || die "sshd не перечитал конфиг"
  fi
  check root_login_off bash -c 'sshd -T | grep -q "^permitrootlogin no"'
  check password_off bash -c 'sshd -T | grep -q "^passwordauthentication no"'
  check kbd_off bash -c 'sshd -T | grep -q "^kbdinteractiveauthentication no"'
fi
finish
