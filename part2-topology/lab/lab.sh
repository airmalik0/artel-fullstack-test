#!/usr/bin/env bash
# Стенд client <-> tspu <-> server на qemu + HVF (мак) с arm64 Debian 13.
# Использование: ./lab.sh fetch | up | down | status | ssh <vm> [команда] | provision
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${LAB_WORK:-$HOME/Projects/artel-test-work/part2/vm}"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2"
BASE="$WORK/debian-13-arm64.qcow2"
KEY="$WORK/lab_ed25519"
RUN="$WORK/run"
MEM="${LAB_MEM:-2048}"; SMP="${LAB_SMP:-2}"
EDK2="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd"
vms=(client tspu server)
port_of() { case $1 in client) echo 2221;; tspu) echo 2222;; server) echo 2223;; esac; }
num_of()  { case $1 in client) echo 1;; tspu) echo 2;; server) echo 3;; esac; }
SSHOPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o ControlMaster=auto -o ControlPersist=600 -o "ControlPath=$RUN/%r@%h:%p" -o ServerAliveInterval=15)

cmd_fetch() {
  mkdir -p "$WORK" "$RUN"
  [ -f "$BASE" ] || curl -fL -o "$BASE" "$IMG_URL"
  [ -f "$KEY" ]  || ssh-keygen -q -t ed25519 -N '' -C lab -f "$KEY"
}

net_config() {
  case $1 in
    client) cat <<N
version: 2
ethernets:
  mgmt0: {match: {macaddress: "52:54:00:aa:01:00"}, set-name: mgmt0, dhcp4: true}
  lana:
    match: {macaddress: "52:54:00:aa:01:01"}
    set-name: lana
    addresses: [10.10.1.2/24]
    routes: [{to: 10.10.2.0/24, via: 10.10.1.1}]
N
    ;;
    tspu) cat <<N
version: 2
ethernets:
  mgmt0: {match: {macaddress: "52:54:00:aa:02:00"}, set-name: mgmt0, dhcp4: true}
  lana: {match: {macaddress: "52:54:00:aa:02:01"}, set-name: lana, addresses: [10.10.1.1/24]}
  lanb: {match: {macaddress: "52:54:00:aa:02:02"}, set-name: lanb, addresses: [10.10.2.1/24]}
N
    ;;
    server) cat <<N
version: 2
ethernets:
  mgmt0: {match: {macaddress: "52:54:00:aa:03:00"}, set-name: mgmt0, dhcp4: true}
  lanb:
    match: {macaddress: "52:54:00:aa:03:02"}
    set-name: lanb
    addresses: [10.10.2.2/24]
    routes: [{to: 10.10.1.0/24, via: 10.10.2.1}]
N
    ;;
  esac
}

make_seed() {
  local vm=$1 d="$WORK/$vm-seed"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/user-data" <<U
#cloud-config
hostname: $vm
users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
growpart: {mode: auto, devices: ["/"]}
U
  echo "instance-id: $vm-$(date +%s)" > "$d/meta-data"
  net_config "$vm" > "$d/network-config"
  rm -f "$WORK/$vm-seed.iso"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$WORK/$vm-seed.iso" "$d"
}

start_vm() {
  local vm=$1 n; n=$(num_of "$vm")
  local disk="$WORK/$vm.qcow2"
  if [ ! -f "$disk" ]; then
    qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$disk" 8G
    make_seed "$vm"
  fi
  local nics=(-netdev "user,id=mgmt,hostfwd=tcp:127.0.0.1:$(port_of "$vm")-:22"
              -device "virtio-net-pci,netdev=mgmt,mac=52:54:00:aa:0$n:00")
  case $vm in
    client) nics+=(-netdev "stream,id=lana,server=off,reconnect-ms=1000,addr.type=unix,addr.path=$RUN/a.sock"
                   -device "virtio-net-pci,netdev=lana,mac=52:54:00:aa:01:01") ;;
    tspu)   nics+=(-netdev "stream,id=lana,server=on,addr.type=unix,addr.path=$RUN/a.sock"
                   -device "virtio-net-pci,netdev=lana,mac=52:54:00:aa:02:01"
                   -netdev "stream,id=lanb,server=on,addr.type=unix,addr.path=$RUN/b.sock"
                   -device "virtio-net-pci,netdev=lanb,mac=52:54:00:aa:02:02") ;;
    server) nics+=(-netdev "stream,id=lanb,server=off,reconnect-ms=1000,addr.type=unix,addr.path=$RUN/b.sock"
                   -device "virtio-net-pci,netdev=lanb,mac=52:54:00:aa:03:02") ;;
  esac
  qemu-system-aarch64 -name "artel-p2-$vm" -M virt -accel hvf -cpu host -smp "$SMP" -m "$MEM" \
    -drive "if=pflash,format=raw,readonly=on,file=$EDK2" \
    -drive "if=virtio,file=$disk" \
    -drive "if=virtio,format=raw,readonly=on,file=$WORK/$vm-seed.iso" \
    "${nics[@]}" -display none -serial "file:$RUN/$vm.log" \
    -daemonize -pidfile "$RUN/$vm.pid"
}

cmd_up() {
  cmd_fetch
  rm -f "$RUN"/*.sock
  start_vm tspu; sleep 1; start_vm client; start_vm server
  for vm in "${vms[@]}"; do
    for _ in $(seq 1 90); do
      ssh "${SSHOPTS[@]}" -o ConnectTimeout=2 -p "$(port_of "$vm")" lab@127.0.0.1 true 2>/dev/null && break
      sleep 2
    done
    ssh "${SSHOPTS[@]}" -p "$(port_of "$vm")" lab@127.0.0.1 "cloud-init status --wait >/dev/null 2>&1 || true; hostname; uname -r"
  done
}

cmd_down() {
  for vm in "${vms[@]}"; do
    if [ -f "$RUN/$vm.pid" ]; then
      ssh "${SSHOPTS[@]}" -o ConnectTimeout=3 -p "$(port_of "$vm")" lab@127.0.0.1 "sudo poweroff" 2>/dev/null || true
    fi
  done
  sleep 6
  for vm in "${vms[@]}"; do
    if [ -f "$RUN/$vm.pid" ]; then
      pid=$(cat "$RUN/$vm.pid"); kill "$pid" 2>/dev/null || true; rm -f "$RUN/$vm.pid"
    fi
  done
}

cmd_status() {
  for vm in "${vms[@]}"; do
    if [ -f "$RUN/$vm.pid" ] && kill -0 "$(cat "$RUN/$vm.pid")" 2>/dev/null; then echo "$vm up pid $(cat "$RUN/$vm.pid")"; else echo "$vm down"; fi
  done
}

cmd_ssh() { local vm=$1; shift; ssh "${SSHOPTS[@]}" -p "$(port_of "$vm")" lab@127.0.0.1 "$@"; }
cmd_scp() { local vm=$1 src=$2 dst=$3; scp -q -r "${SSHOPTS[@]}" -P "$(port_of "$vm")" "$src" "lab@127.0.0.1:$dst"; }

cmd_provision() {
  for vm in "${vms[@]}"; do
    cmd_scp "$vm" "$HERE/provision" /tmp/provision
    cmd_ssh "$vm" "sudo bash /tmp/provision/$vm.sh" > "$RUN/provision-$vm.log" 2>&1 &
  done
  wait
  tail -n 2 "$RUN"/provision-*.log
}

c=${1:-}; shift || true
case "$c" in
  fetch|up|down|status|provision) "cmd_$c" ;;
  ssh) cmd_ssh "$@" ;;
  scp) cmd_scp "$@" ;;
  *) echo "usage: $0 fetch|up|down|status|provision|ssh <vm> [cmd]|scp <vm> <src> <dst>"; exit 2 ;;
esac
