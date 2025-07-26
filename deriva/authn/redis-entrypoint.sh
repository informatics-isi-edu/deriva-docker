#!/bin/sh

set -e

# Read secret (strip any CR/LF)
PW=$(tr -d '\r\n' < /run/secrets/credenza_db_password)
# Render the real redis.conf
sed "s|{{PASSWORD}}|$PW|g" /usr/local/etc/redis/redis.conf.in > /data/redis.conf
# Launch Redis via the official entrypoint
exec docker-entrypoint.sh redis-server /data/redis.conf