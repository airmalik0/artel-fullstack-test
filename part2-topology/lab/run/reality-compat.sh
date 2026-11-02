#!/usr/bin/env bash
# Клиент sing-box против разных версий Xray на узле: один и тот же ключ, порт 9443 на .11. Пишет CSV в stdout.
# Причина отказа на новых версиях: XTLS/REALITY 8cdf7bf9 отвергает ClientHello без X25519MLKEM768,
# а sing-box вырезает этот share из ClientHello (common/tls/reality_client.go).
cd "$(dirname "$0")/.."
echo "xray_server,client,rep,result"
for v in v26.6.27 v26.9.9 v26.10.31; do
  ./lab.sh ssh server "bin=/tmp/x-$v/xray; [ $v = v26.10.31 ] && bin=/usr/local/bin/xray
    [ -x \$bin ] || { curl -fsSL --max-time 90 -o /tmp/x.zip https://github.com/XTLS/Xray-core/releases/download/$v/Xray-linux-arm64-v8a.zip; mkdir -p /tmp/x-$v; python3 -c \"import zipfile;zipfile.ZipFile('/tmp/x.zip').extract('xray','/tmp/x-$v')\"; chmod +x \$bin; }
    sudo jq '.inbounds=[.inbounds[0]] | .inbounds[0].port=9443' /etc/lab/xray-server.json > /tmp/xs.json
    nohup \$bin run -c /tmp/xs.json >/tmp/xs.log 2>&1 </dev/null & echo \$! > /tmp/xs.pid; sleep 1"
  for rep in 1 2 3; do
    ./lab.sh ssh client "jq '(.outbounds[0].server_port)=9443 | .log.output=\"/tmp/sbt.log\"' /tmp/sb.json > /tmp/sbt.json
      sudo rm -f /tmp/sbt.log; sudo sing-box run -c /tmp/sbt.json >/dev/null 2>&1 & sleep 4; sudo kill \$(pgrep -x sing-box) 2>/dev/null
      sudo grep -m1 -E 'outbound reality (un)?available' /tmp/sbt.log | sed -E 's/.*outbound reality //; s/,/;/g; s/ ?[0-9]+ms//' | cut -c1-60 | sed 's/^/$v,sing-box-1.14.4,$rep,/'
      sed 's/\"port\": *443/\"port\":9443/; s/@H@/10.10.2.11/' /etc/lab/xray-reality.json > /tmp/xc.json
      nohup xray run -c /tmp/xc.json >/tmp/xc.log 2>&1 </dev/null & p=\$!; sleep 1
      n=\$(curl -s --max-time 4 -o /dev/null -w '%{size_download}' --socks5-hostname 127.0.0.1:10801 http://127.0.0.1:8080/1k); kill \$p
      [ \"\$n\" = 1024 ] && echo $v,xray-26.10.31,$rep,available || echo $v,xray-26.10.31,$rep,unavailable"
  done
  ./lab.sh ssh server 'kill $(cat /tmp/xs.pid)'; sleep 0.5
done
