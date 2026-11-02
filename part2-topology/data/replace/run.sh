#!/usr/bin/env bash
# Замер смены выходного узла на DigitalOcean: от запроса на создание дроплета до первого успешного
# запроса через новый узел по Reality и по Hysteria2. Клиент: мак, бинарники тех же версий в $BIN.
# run.sh <повторов> <out.csv>. Дроплет artel-p2-replace-N удаляется по id сразу после повтора.
set -euo pipefail
N=$1; OUT=$2; BIN="${BIN:-$HOME/artel-lab/bin}"
export DIGITALOCEAN_ACCESS_TOKEN="$(cat ~/.config/do-token)"
echo "rep,created_s,reality_ok_s,hy2_ok_s,droplet_id" > "$OUT"
for r in $(seq 1 "$N"); do
  UUID=$("$BIN/xray" uuid); X=$("$BIN/xray" x25519)
  PRIV=$(echo "$X" | awk -F': ' 'NR==1{print $2}'); PUB=$(echo "$X" | awk -F': ' 'NR==2{print $2}')
  SID=$(openssl rand -hex 8); HP=$(openssl rand -hex 16)
  UD=$(mktemp); cat > "$UD" <<C
#!/bin/bash
curl -fsSL -o /tmp/x.zip https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-64.zip
apt-get update -qq; apt-get install -y -qq unzip openssl >/dev/null
unzip -oq /tmp/x.zip xray -d /usr/local/bin
curl -fsSL -o /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria /usr/local/bin/xray
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3 -keyout /root/k -out /root/c -subj /CN=www.microsoft.com 2>/dev/null
cat > /root/x.json <<J
{"inbounds":[{"port":443,"protocol":"vless","settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
"streamSettings":{"network":"raw","security":"reality","realitySettings":{"target":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PRIV","shortIds":["$SID"]}}}],
"outbounds":[{"protocol":"freedom"}]}
J
cat > /root/h.yaml <<Y
listen: :443
tls: {cert: /root/c, key: /root/k}
auth: {type: password, password: $HP}
Y
nohup xray run -c /root/x.json >/dev/null 2>&1 &
HYSTERIA_DISABLE_UPDATE_CHECK=1 nohup hysteria server -c /root/h.yaml >/dev/null 2>&1 &
C
  t0=$(python3 -c 'import time;print(time.time())')
  L=$(doctl compute droplet create "artel-p2-replace-$r" --region fra1 --size s-1vcpu-512mb-10gb --image debian-13-x64 --ssh-keys 60396056 --tag-name lab --user-data-file "$UD" --wait --format ID,PublicIPv4 --no-header)
  rm -f "$UD"; ID=$(echo "$L" | awk '{print $1}'); IP=$(echo "$L" | awk '{print $2}')
  t1=$(python3 -c 'import time;print(time.time())')
  W=$(mktemp -d)
  cat > "$W/rx.json" <<J
{"inbounds":[{"listen":"127.0.0.1","port":10811,"protocol":"socks"}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"$IP","port":443,"users":[{"id":"$UUID","encryption":"none","flow":"xtls-rprx-vision"}]}]},
"streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverName":"www.microsoft.com","fingerprint":"chrome","publicKey":"$PUB","shortId":"$SID"}}}]}
J
  printf 'server: %s:443\nauth: %s\ntls: {insecure: true, sni: www.microsoft.com}\nsocks5: {listen: 127.0.0.1:10812}\n' "$IP" "$HP" > "$W/rh.yaml"
  "$BIN/xray" run -c "$W/rx.json" >"$W/rx.log" 2>&1 & XP=$!
  HP2=""; t2=""; t3=""
  for _ in $(seq 1 150); do
    if [ -z "$t2" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --socks5-hostname 127.0.0.1:10811 https://www.gstatic.com/generate_204)" = 204 ]; then
      t2=$(python3 -c 'import time;print(time.time())')
      HYSTERIA_DISABLE_UPDATE_CHECK=1 "$BIN/hysteria" client -c "$W/rh.yaml" >"$W/rh.log" 2>&1 & HP2=$!
    fi
    if [ -n "$t2" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --socks5-hostname 127.0.0.1:10812 https://www.gstatic.com/generate_204)" = 204 ]; then
      t3=$(python3 -c 'import time;print(time.time())'); break
    fi
    sleep 1
  done
  python3 -c "print('$r,%.1f,%s,%s,$ID'%($t1-$t0, '%.1f'%($t2-$t0) if '$t2' else '', '%.1f'%($t3-$t0) if '$t3' else ''))" >> "$OUT"
  kill "$XP" ${HP2:+"$HP2"} 2>/dev/null || true; rm -rf "$W"
  doctl compute droplet delete "$ID" --force
done
doctl compute droplet list --format ID,Name --no-header | grep artel-p2-replace || echo "replace droplets gone"
