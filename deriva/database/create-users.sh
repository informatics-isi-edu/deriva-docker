#!/bin/bash
set -e

DERIVA_POSTGRES_USERS=webauthn,ermrest,hatrac,deriva

IFS=',' read -ra USERS <<< "$DERIVA_POSTGRES_USERS"
COUNTER=1
for USER in "${USERS[@]}"; do
  ID="99$COUNTER"

  echo "Creating user $USER with UID/GID $ID"

  groupadd -g "$ID" "$USER"
  useradd -u "$ID" -g "$ID" -r -s /usr/sbin/nologin -d /nonexistent "$USER"

  ((COUNTER++))
done