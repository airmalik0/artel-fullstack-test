#!/usr/bin/env bash
# Генерирует ключи и конфиги всех протоколов на server; клиентская часть в /etc/lab/cli.
set -euo pipefail
D=/etc/lab; C=$D/cli; rm -rf "$D"/*; mkdir -p "$C" "$D/ca"; cd "$D"
UUID=$(xray uuid)
X=$(xray x25519); PRIV=$(echo "$X" | awk -F': ' 'NR==1{print $2}'); PUB=$(echo "$X" | awk -F': ' 'NR==2{print $2}')
SID=$(openssl rand -hex 8)
SSKEY=$(openssl rand -base64 16); HYPASS=$(openssl rand -hex 16); OBFS=$(openssl rand -hex 16)

# Сертификат на все тестовые имена (самоподписанный, клиенты в стенде его не проверяют).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -keyout cert.key -out cert.crt -subj /CN=allowed.example \
  -addext "subjectAltName=DNS:allowed.example,DNS:other.example,DNS:blocked.example" 2>/dev/null

cat > nginx.conf <<N
worker_processes 2; pid /run/lab-nginx.pid; error_log /var/log/lab-nginx.log warn;
events { worker_connections 2048; }
http {
  default_type application/octet-stream; access_log off; sendfile on; keepalive_timeout 30;
  server { listen 0.0.0.0:8080; root /srv/www; }
  server {
    listen 10.10.2.10:443 ssl; listen 127.0.0.1:8443 ssl; http2 on;
    ssl_certificate $D/cert.crt; ssl_certificate_key $D/cert.key;
    ssl_protocols TLSv1.2 TLSv1.3; root /srv/www;
  }
}
N

rs() { cat <<J
{"show":false,"target":"127.0.0.1:8443","serverNames":["allowed.example","other.example","blocked.example"],"privateKey":"$PRIV","shortIds":["$SID"]}
J
}
cat > xray-server.json <<J
{"log":{"loglevel":"warning"},
 "inbounds":[
  {"listen":"10.10.2.11","port":443,"protocol":"vless",
   "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
   "streamSettings":{"network":"raw","security":"reality","realitySettings":$(rs)}},
  {"listen":"10.10.2.12","port":443,"protocol":"vless",
   "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
   "streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/x"},"security":"reality","realitySettings":$(rs)}},
  {"listen":"10.10.2.13","port":8388,"protocol":"shadowsocks",
   "settings":{"method":"2022-blake3-aes-128-gcm","password":"$SSKEY","network":"tcp,udp"}}
 ],
 "outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","network":"tcp","ip":["127.0.0.0/8"],"port":"8080"}]}}]}
J

hy() { # имя адрес obfs
cat > "$D/hy-$1.yaml" <<Y
listen: $2:443
tls: {cert: $D/cert.crt, key: $D/cert.key}
auth: {type: password, password: $HYPASS}
masquerade: {type: string, string: {content: ok, statusCode: 200}}
$3
Y
}
hy plain 10.10.2.11 ""
hy obfs 10.10.2.18 "obfs: {type: salamander, salamander: {password: $OBFS}}"

# WireGuard и AmneziaWG
WS=$(wg genkey); WSP=$(echo "$WS" | wg pubkey); WC=$(wg genkey); WCP=$(echo "$WC" | wg pubkey)
AS=$(wg genkey); ASP=$(echo "$AS" | wg pubkey); AC=$(wg genkey); ACP=$(echo "$AC" | wg pubkey)
AP="Jc = 4
Jmin = 40
Jmax = 70
S1 = 52
S2 = 112
H1 = $((RANDOM*20000+5))
H2 = $((RANDOM*20000+6))
H3 = $((RANDOM*20000+7))
H4 = $((RANDOM*20000+8))"
printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.99.1.2/32\n' "$WS" "$WCP" > wg.conf
printf '[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nEndpoint = @H@:51820\nAllowedIPs = 10.99.1.1/32\n' "$WC" "$WSP" > cli/wg.conf
printf '[Interface]\nPrivateKey = %s\nListenPort = 51821\n%s\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.99.2.2/32\n' "$AS" "$AP" "$ACP" > awg.conf
printf '[Interface]\nPrivateKey = %s\n%s\n[Peer]\nPublicKey = %s\nEndpoint = @H@:51821\nAllowedIPs = 10.99.2.1/32\n' "$AC" "$AP" "$ASP" > cli/awg.conf

# OpenVPN: своя CA, режим TLS.
cd ca
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -keyout ca.key -out ca.crt -subj /CN=lab-ca 2>/dev/null
for n in server client; do
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $n.key -out $n.csr -subj /CN=$n 2>/dev/null
  printf 'keyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=%sAuth\n' "$n" > ext
  openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -out $n.crt -extfile ext 2>/dev/null
done
cd ..
ov() { cat > ovpn-$1.conf <<O
dev tun$2
proto $6
local $3
port $4
server 10.99.$5.0 255.255.255.0
topology subnet
ca $D/ca/ca.crt
cert $D/ca/server.crt
key $D/ca/server.key
dh none
ecdh-curve prime256v1
data-ciphers AES-128-GCM
verb 1
O
}
ov udp 1 10.10.2.16 1194 3 udp; ov tcp 2 10.10.2.17 443 4 tcp-server
cp ca/ca.crt ca/client.crt ca/client.key cli/
ovc() { cat > cli/ovpn-$1.conf <<O
client
dev tun
proto $2
remote @H@ $3
nobind
ca /etc/lab/ca.crt
cert /etc/lab/client.crt
key /etc/lab/client.key
data-ciphers AES-128-GCM
remote-cert-tls server
connect-retry 1
connect-retry-max 3
verb 1
O
}
ovc udp udp 1194; ovc tcp tcp-client 443

# Клиенты Xray
xc() { # имя sni net flow
  local ss='"network":"raw"'; [ "$3" = xhttp ] && ss='"network":"xhttp","xhttpSettings":{"path":"/x"}'
  cat > cli/xray-$1.json <<J
{"log":{"loglevel":"warning"},
 "inbounds":[{"listen":"127.0.0.1","port":10801,"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"@H@","port":443,"users":[{"id":"$UUID","encryption":"none","flow":"$4"}]}]},
  "streamSettings":{$ss,"security":"reality","realitySettings":{"serverName":"$2","fingerprint":"chrome","publicKey":"$PUB","shortId":"$SID","spiderX":"/"}}}]}
J
}
xc reality other.example raw xtls-rprx-vision
xc reality-wl allowed.example raw xtls-rprx-vision
xc xhttp other.example xhttp ""
cat > cli/xray-ss2022.json <<J
{"log":{"loglevel":"warning"},
 "inbounds":[{"listen":"127.0.0.1","port":10801,"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"protocol":"shadowsocks","settings":{"servers":[{"address":"@H@","port":8388,"method":"2022-blake3-aes-128-gcm","password":"$SSKEY"}]}}]}
J
hc() { cat > cli/hy-$1.yaml <<Y
server: @H@:443
auth: $HYPASS
tls: {sni: $2, insecure: true}
socks5: {listen: 127.0.0.1:10801}
$3
Y
}
hc plain other.example ""; hc blk blocked.example ""
hc obfs other.example "obfs: {type: salamander, salamander: {password: $OBFS}}"
chmod -R a+rX "$C"; tar -C "$C" -czf /tmp/cli.tgz .; chmod a+r /tmp/cli.tgz
echo generated
