# Отдаёт параметры клиента строкой ::secret:: Она не попадает ни в журнал, ни в
# JSON шага: step.sh забирает её и пишет в output/<host>/client/ с правами 600.
[ -s /etc/xray/reality.env ] || die "нет ключей Reality: сначала шаг xray"
[ -s /etc/hysteria/auth.env ] || die "нет пароля Hysteria: сначала шаг hysteria"
PUBLIC_KEY="$(sed -n 's/^PUBLIC_KEY=//p' /etc/xray/reality.env)"
UUID="$(sed -n 's/^UUID=//p' /etc/xray/reality.env)"
SHORT_ID="$(sed -n 's/^SHORT_ID=//p' /etc/xray/reality.env)"
PASSWORD="$(sed -n 's/^PASSWORD=//p' /etc/hysteria/auth.env)"
PIN="$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 | cut -d= -f2)"
python3 - "$PUBLIC_KEY" "$UUID" "$SHORT_ID" "$PASSWORD" "$PIN" <<'PY'
import base64, json, sys
keys = ("public_key", "uuid", "short_id", "password", "pin")
blob = json.dumps(dict(zip(keys, sys.argv[1:6]))).encode()
print("::secret::" + base64.b64encode(blob).decode())
PY
check params_present bash -c "[ -n '${PUBLIC_KEY:0:4}' ] && [ -n '${UUID:0:4}' ] && [ -n '${PIN:0:4}' ]"
finish
