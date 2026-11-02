#!/usr/bin/env bash
# Заливает скрипты на ВМ и пересобирает конфиги. sync.sh [gen]
set -euo pipefail
cd "$(dirname "$0")"
W="${LAB_WORK:-$HOME/artel-lab/vm}"
./lab.sh ssh server 'rm -rf /tmp/provision'; ./lab.sh scp server provision /tmp/provision
if [ "${1:-}" = gen ]; then
  ./lab.sh ssh server 'sudo bash /tmp/provision/gen-services.sh >/dev/null'
  ./lab.sh ssh server 'cat /tmp/cli.tgz' > "$W/cli.tgz"
  ./lab.sh ssh client 'cat > /tmp/cli.tgz' < "$W/cli.tgz"
  ./lab.sh ssh client 'sudo tar -C /etc/lab -xzf /tmp/cli.tgz'
fi
./lab.sh ssh server 'sudo bash /tmp/provision/services-up.sh' > /dev/null 2>&1
for f in proto.sh fetch.sh parallel.sh rep.sh sb-config.py watchdog.py fo-probe.py sbctl.sh; do ./lab.sh scp client run/$f /tmp/$f; done
./lab.sh ssh client 'sudo cp /tmp/proto.sh /tmp/fetch.sh /tmp/parallel.sh /tmp/rep.sh /tmp/sb-config.py /tmp/watchdog.py /tmp/fo-probe.py /tmp/sbctl.sh /opt/lab/; sudo chmod +x /opt/lab/*.sh; sudo ethtool -K lana tso off gso off gro off lro off 2>/dev/null || true'
./lab.sh scp tspu tspu/ /tmp/tspu-new
./lab.sh scp tspu run/probe.py /tmp/tspu-new/probe.py
./lab.sh ssh tspu 'sudo cp -r /tmp/tspu-new/* /opt/lab/; rm -rf /tmp/tspu-new; sudo chmod +x /opt/lab/*.sh /opt/lab/*.py 2>/dev/null || true; sudo modprobe nfnetlink_queue'
