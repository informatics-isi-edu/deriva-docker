#!/bin/bash
set -e

source /usr/local/lib/utils.sh
source /usr/local/lib/runtime.sh

# Suppress cert verify warnings in test environments
if [[ "$DEPLOY_ENV" != "prod" && "$DEPLOY_ENV" != "staging" && "$DEPLOY_ENV" != "dev" ]]; then
  export PYTHONWARNINGS="ignore:Unverified HTTPS request"
fi

# Inject Keycloak secret from file into env var
inject_secret /run/secrets/keycloak_deriva_client_secret KEYCLOAK_DERIVA_CLIENT_SECRET

# Emit keycloak_client_secret.json from env vars (if secret is defined)
mkdir -p /credenza/secrets
if [[ -n "$KEYCLOAK_DERIVA_CLIENT_SECRET" ]]; then
  if [[ ! -f /credenza/secrets/keycloak_client_secret.json ]]; then
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<EOF
{
  "client_id": "deriva-client",
  "client_secret": "\${KEYCLOAK_DERIVA_CLIENT_SECRET}"
}
EOF
    substitute_env_vars "$tmpfile" /credenza/secrets/keycloak_client_secret.json
    rm -f "$tmpfile"
  fi
fi

# Perform substitution on the profiles config
input_file="/credenza/config/oidc_idp_profiles.json.in"
output_file="/credenza/config/oidc_idp_profiles.json"

if [[ ! -f "$input_file" ]]; then
  log "ERROR: Missing template file: $input_file"
  exit 1
fi

if [[ ! -f "$output_file" ]]; then
  substitute_env_vars "$input_file" "$output_file"
fi

# Inject credenza_db_password and credenza_encryption_key into env
inject_secret /run/secrets/credenza_db_password CREDENZA_DB_PASSWORD
inject_secret /run/secrets/credenza_encryption_key CREDENZA_ENCRYPTION_KEY

# set default command
if [ $# -eq 0 ]; then
  set -- gunicorn --workers 1 --threads 4 --bind 0.0.0.0:8999 credenza.credenza_wsgi:application
fi

# run processes
start_rsyslog
start_main_process "$@"
monitor_loop