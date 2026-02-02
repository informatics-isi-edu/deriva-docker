#!/bin/sh
set -e

INT_CERT_PATH="/certs/deriva.crt"
INT_KEY_PATH="/certs/deriva.key"

TEMPLATE="/etc/traefik/config/traefik_tls_certs.yaml.template"
TARGET="/etc/traefik/config/traefik_tls_certs.yaml"

replace() {
  sed \
    -e "s|\${CERT_DIR}|${CERT_DIR}|g" \
    -e "s|\${CERT_FILENAME}|${CERT_FILENAME}|g" \
    -e "s|\${KEY_FILENAME}|${KEY_FILENAME}|g" \
    "$TEMPLATE" > "$TARGET"
}

# clean up any previously generated configuration
if [ -f "$TARGET" ]; then
  rm -f "$TARGET"
fi

if [ -n "${CERT_DIR-}" ] && [ -n "${CERT_FILENAME-}" ] && [ -n "${KEY_FILENAME-}" ]; then
  EXT_CERT_PATH="/certs-ext/${CERT_DIR}/${CERT_FILENAME}"
  EXT_KEY_PATH="/certs-ext/${CERT_DIR}/${KEY_FILENAME}"

  if [ -f "$EXT_CERT_PATH" ] && [ -f "$EXT_KEY_PATH" ]; then
    echo "🟢   Found externally mounted TLS certs, using them."
    CERT_DIR="/certs-ext/${CERT_DIR}"
    replace
    exec traefik "$@"
  fi
fi

if [ -f "$INT_CERT_PATH" ] && [ -f "$INT_KEY_PATH" ]; then
  echo "🟢   Found TLS certs on internal shared volume, using them."
  CERT_DIR="/certs"
  CERT_FILENAME="deriva.crt"
  KEY_FILENAME="deriva.key"
  replace
fi

exec traefik "$@"
