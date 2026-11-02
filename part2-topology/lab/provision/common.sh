#!/usr/bin/env bash
# Общее для всех ВМ: пакеты и версии протокольного ПО закреплены здесь.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
XRAY_VER=v26.10.31
HY_VER=app/v2.13.0
AWG_TOOLS_VER=v3.1.20260812
AWG_GO_REF=master
apt_install() { apt-get update -qq; apt-get install -y -qq "$@" >/dev/null; }
install_xray() {
  apt_install unzip
  curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/Xray-linux-arm64-v8a.zip"
  unzip -oq /tmp/xray.zip xray -d /usr/local/bin; chmod +x /usr/local/bin/xray
}
install_hysteria() {
  curl -fsSL -o /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/$HY_VER/hysteria-linux-arm64"
  chmod +x /usr/local/bin/hysteria
}
install_awg() {
  apt_install golang-go build-essential git make
  export HOME=/root GOPATH=/root/go GOCACHE=/root/.cache/go GOTOOLCHAIN=auto
  [ -d /opt/awg-go ] || git clone -q https://github.com/amnezia-vpn/amneziawg-go /opt/awg-go
  (cd /opt/awg-go && git checkout -q "$AWG_GO_REF" && make -s && cp amneziawg-go /usr/local/bin/)
  [ -d /opt/awg-tools ] || git clone -q --branch "$AWG_TOOLS_VER" https://github.com/amnezia-vpn/amneziawg-tools /opt/awg-tools
  (cd /opt/awg-tools/src && make -s && cp wg /usr/local/bin/awg)
}
offloads_off() { for i in lana lanb; do [ -e /sys/class/net/$i ] && ethtool -K $i tso off gso off gro off lro off >/dev/null 2>&1 || true; done; }
