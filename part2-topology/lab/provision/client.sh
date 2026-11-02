#!/usr/bin/env bash
source /tmp/provision/common.sh
apt_install ethtool curl wireguard-tools openvpn iproute2 jq tcpdump
install_xray; install_hysteria; install_awg
mkdir -p /opt/lab /etc/lab
cat > /etc/sysctl.d/90-lab.conf <<S
net.core.rmem_max=33554432
net.core.wmem_max=33554432
S
sysctl -q --system
offloads_off
echo provisioned client
