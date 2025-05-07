#!/bin/sh

set -e

# Ensure required env vars are set
: "${CERT_DIR:?Missing CERT_DIR}"
: "${CERT_FILENAME:?Missing CERT_FILENAME}"
: "${KEY_FILENAME:?Missing KEY_FILENAME}"

EXT_CERT_PATH="/certs-ext/${CERT_DIR}/${CERT_FILENAME}"
EXT_KEY_PATH="/certs-ext/${CERT_DIR}/${KEY_FILENAME}"

INT_CERT_PATH="/certs/deriva.crt"
INT_KEY_PATH="/certs/deriva.key"

TEMPLATE="/etc/traefik/config/traefik_tls_certs.yaml.template"
TARGET="/etc/traefik/config/traefik_tls_certs.yaml"

replace ()
{
  sed \
    -e "s|\${CERT_DIR}|${CERT_DIR}|g" \
    -e "s|\${CERT_FILENAME}|${CERT_FILENAME}|g" \
    -e "s|\${KEY_FILENAME}|${KEY_FILENAME}|g" \
    "$TEMPLATE" > "$TARGET"
}

if [ -f "$EXT_CERT_PATH" ] && [ -f "$EXT_KEY_PATH" ]; then
  echo "🟢   Found externally mounted TLS certs, using them."
  CERT_DIR="/certs-ext/${CERT_DIR}"
  replace
elif [ -f "$INT_CERT_PATH" ] && [ -f "$INT_KEY_PATH" ]; then
  echo "🟢   Found TLS certs on internal shared volume, using them."
  CERT_DIR="/certs"
  CERT_FILENAME="deriva.crt"
  KEY_FILENAME="deriva.key"
  replace
fi

exec traefik "$@"
