#!/bin/bash
# Состояние «до»: та же ошибка, что на сервере. Пароль открытым текстом и в аргументах openssl.
# Пароль здесь учебный, он только для стенда.
set -e
STAMP=$(date +%Y-%m-%d)
DEST=/var/backups/demo
PASS=stand-only-not-a-secret
mkdir -p "$DEST"
tar czf - -C /opt/bots demo \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -k $PASS -out "$DEST/demo-src-$STAMP.tar.gz.enc"
find "$DEST" -name '*.tar.gz.enc' -mtime +7 -delete
