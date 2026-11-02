#!/usr/bin/env bash
source /tmp/provision/common.sh
apt_install nftables conntrack ethtool tcpdump python3-venv python3-dev gcc libnetfilter-queue-dev libnfnetlink-dev python3-cryptography iproute2
python3 -m venv --system-site-packages /opt/tspu-venv
/opt/tspu-venv/bin/pip -q install NetfilterQueue aioquic
mkdir -p /opt/lab /etc/lab
cat > /etc/sysctl.d/90-lab.conf <<S
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_acct=1
net.netfilter.nf_conntrack_tcp_be_liberal=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
S
modprobe nf_conntrack; sysctl -q --system
echo provisioned tspu
