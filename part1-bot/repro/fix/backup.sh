#!/bin/bash
# Шифрованный бэкап. Пароль только в файле 600: нет ни в скрипте, ни в аргументах openssl.
# Восстановление:
#   openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$PASS_FILE -in ФАЙЛ.enc | tar tzf -
set -eu
umask 077
. /opt/botfix/botfix.env
[ "$(stat -c %a "$PASS_FILE")" = 600 ] || { echo "права $PASS_FILE не 600" >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/$BACKUP_NAME-$(date -u +%Y-%m-%dT%H%M%SZ).tar.gz.enc"
tar czf - -C "$(dirname "$BOT_DIR")" "$(basename "$BOT_DIR")" \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASS_FILE" -out "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
find "$BACKUP_DIR" -name '*.tar.gz.enc' -mtime +7 -delete
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup $OUT $(stat -c %s "$OUT") bytes"
