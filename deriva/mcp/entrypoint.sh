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

# Seed any files missing from /etc/deriva-mcp/ (e.g. when a bind-mount is
# used for operator customization and the mount dir is empty on first deploy).
# Files that already exist are never overwritten -- operator edits are preserved.
if [[ -d /etc/deriva-mcp-defaults ]]; then
  for _f in /etc/deriva-mcp-defaults/*; do
    _base="$(basename "$_f")"
    if [[ ! -f "/etc/deriva-mcp/$_base" ]]; then
      echo "Seeding /etc/deriva-mcp/$_base from image defaults"
      cp "$_f" "/etc/deriva-mcp/$_base"
    fi
  done
  unset _f _base
fi

# Inject client secret from Docker secret file into the expected env var
inject_secret /run/secrets/mcp_client_secret DERIVA_MCP_CLIENT_SECRET

start_rsyslog
start_main_process "$@"
monitor_loop