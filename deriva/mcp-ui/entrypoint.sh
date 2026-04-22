#!/bin/bash
set -e

source /usr/local/lib/utils.sh
source /usr/local/lib/runtime.sh

# Suppress unverified HTTPS warnings in non-production environments
if [[ "$DEPLOY_ENV" != "prod" && "$DEPLOY_ENV" != "staging" && "$DEPLOY_ENV" != "dev" ]]; then
    export PYTHONWARNINGS="ignore:Unverified HTTPS request"
fi

# Install an externally-mounted CA certificate so Python requests and httpx
# trust the dev/staging TLS certificate.  CA_FILENAME must be set in the
# environment and the certificate must be present at /certs-ext/$CA_FILENAME.
CERT_CA_PATH="/certs-ext/${CA_FILENAME}"
SYSTEM_CA_CERT_PATH="/usr/local/share/ca-certificates/${CA_FILENAME}"
if [[ -n "$CA_FILENAME" && -f "$CERT_CA_PATH" ]]; then
    echo "Installing CA certificate: $CERT_CA_PATH"
    cp "$CERT_CA_PATH" "$SYSTEM_CA_CERT_PATH"
    update-ca-certificates
fi

# Seed any files missing from /etc/deriva-mcp-ui/ (e.g. when a bind-mount is
# used for operator customization and the mount dir is empty on first deploy).
# Files that already exist are never overwritten -- operator edits are preserved.
if [[ -d /etc/deriva-mcp-ui-defaults ]]; then
  for _f in /etc/deriva-mcp-ui-defaults/*; do
    _base="$(basename "$_f")"
    if [[ ! -f "/etc/deriva-mcp-ui/$_base" ]]; then
      echo "Seeding /etc/deriva-mcp-ui/$_base from image defaults"
      cp "$_f" "/etc/deriva-mcp-ui/$_base"
    fi
  done
  unset _f _base
fi

# Load env file if present (contains non-secret runtime config)
ENV_FILE="/etc/deriva-mcp-ui/deriva-mcp-ui.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

start_rsyslog
start_main_process "$@"
monitor_loop