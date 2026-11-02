#!/bin/bash
# Состояние «до»: воспроизвожу ошибку сервера, пароль лежит в скрипте и уходит в аргументы openssl.
# Пароль учебный, живёт только на стенде.
PASS=stand-only-not-a-secret
archive=/var/backups/demo/demo-src-$(date -u +%F).tar.gz.enc
mkdir -p "${archive%/*}"
tar -C /opt/bots -cz demo | openssl enc -aes-256-cbc -pbkdf2 -k "$PASS" -out "$archive"
