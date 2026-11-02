#!/usr/bin/env bash
source /tmp/provision/common.sh
apt_install ethtool curl wireguard-tools openvpn iproute2 jq tcpdump nginx-light nftables openssl
install_xray; install_hysteria; install_awg
mkdir -p /opt/lab /etc/lab /srv/www
cat > /etc/sysctl.d/90-lab.conf <<S
net.ipv4.ip_forward=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
S
sysctl -q --system
systemctl disable --now nginx >/dev/null 2>&1 || true
offloads_off
for s in 1k:1024 1m:1048576 16m:16777216 256k:262144; do
  head -c "${s#*:}" /dev/urandom > "/srv/www/${s%:*}"
done
echo provisioned server
