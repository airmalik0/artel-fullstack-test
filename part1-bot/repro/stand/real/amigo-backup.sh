#!/bin/bash
# Состояние «до»: пароль учебный, живёт только на стенде.
PASS=stand-only-not-a-secret
archive=/var/backups/amigo/amigo-src-$(date -u +%F).tar.gz.enc
mkdir -p "${archive%/*}"
tar -C /opt/bots -cz amigo | openssl enc -aes-256-cbc -pbkdf2 -k "$PASS" -out "$archive"
