#!/bin/bash
set -e

source /usr/local/lib/utils.sh
source /usr/local/lib/runtime.sh

# Seed any files missing from /credenza/config/ (e.g. when a bind-mount is
# used for operator customisation and the mount dir is empty on first deploy).
# Files that already exist are never overwritten -- operator edits are preserved.
if [[ -d /credenza/config-defaults ]]; then
  for _f in /credenza/config-defaults/*; do
    _base="$(basename "$_f")"
    if [[ ! -f "/credenza/config/$_base" ]]; then
      echo "Seeding /credenza/config/$_base from image defaults"
      cp "$_f" "/credenza/config/$_base"
    fi
  done
  unset _f _base
fi

# CREDENZA_REGEN_CONFIGS: set to "true" to regenerate config files from
# templates even when the destination already exists. Default is "false" --
# existing files are preserved so operator customisations survive restarts.
# Secrets files (/credenza/secrets/) are always regenerated from env vars
# and are not affected by this flag.
CREDENZA_REGEN_CONFIGS="${CREDENZA_REGEN_CONFIGS:-false}"

generate_config() {
  local src="$1" dest="$2"
  shift 2
  if [[ "$CREDENZA_REGEN_CONFIGS" == "true" || ! -f "$dest" ]]; then
    substitute_env_vars "$src" "$dest" "$@"
  else
    echo "Skipping $dest (exists; set CREDENZA_REGEN_CONFIGS=true to regenerate)"
  fi
}

# Suppress cert verify warnings in test environments
if [[ "$DEPLOY_ENV" != "prod" && "$DEPLOY_ENV" != "staging" && "$DEPLOY_ENV" != "dev" ]]; then
  export PYTHONWARNINGS="ignore:Unverified HTTPS request"
fi

# inject secrets into env
inject_secret /run/secrets/credenza_db_password CREDENZA_DB_PASSWORD
inject_secret /run/secrets/credenza_encryption_key CREDENZA_ENCRYPTION_KEY
# optional; only used when Keycloak IDP is configured
inject_secret /run/secrets/keycloak_deriva_client_secret KEYCLOAK_CLIENT_SECRET || true

# Emit keycloak_client_secret.json from env vars (if secret is defined)
mkdir -p /credenza/secrets
if require_envs KEYCLOAK_CLIENT_SECRET; then
  export CLIENT_ID=${KEYCLOAK_CLIENT_ID:-"deriva-client"} CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}
  CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret.json.in"
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/keycloak_client_secret.json"
  substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
   '${CLIENT_ID} ${CLIENT_SECRET}'
fi
if require_envs OKTA_CLIENT_ID OKTA_CLIENT_SECRET; then
  export CLIENT_ID=${OKTA_CLIENT_ID} CLIENT_SECRET=${OKTA_CLIENT_SECRET}
  CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret.json.in"
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/okta_client_secret.json"
  substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
   '${CLIENT_ID} ${CLIENT_SECRET}'
fi
if require_envs COGNITO_CLIENT_ID COGNITO_CLIENT_SECRET; then
  export CLIENT_ID=${COGNITO_CLIENT_ID} CLIENT_SECRET=${COGNITO_CLIENT_SECRET}
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/cognito_client_secret.json"
  if require_envs COGNITO_NATIVE_CLIENT_ID; then
    export NATIVE_CLIENT_ID=${COGNITO_NATIVE_CLIENT_ID}
    CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret_native.json.in"
    substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
     '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
  else
    CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret.json.in"
    substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
     '${CLIENT_ID} ${CLIENT_SECRET}'
  fi
fi
if require_envs GLOBUS_CLIENT_ID GLOBUS_CLIENT_SECRET; then
  export CLIENT_ID=${GLOBUS_CLIENT_ID} CLIENT_SECRET=${GLOBUS_CLIENT_SECRET}
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/globus_client_secret.json"
  if require_envs GLOBUS_NATIVE_CLIENT_ID; then
    export NATIVE_CLIENT_ID=${GLOBUS_NATIVE_CLIENT_ID}
    CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret_native.json.in"
    substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
     '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
  else
    CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret.json.in"
    substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
     '${CLIENT_ID} ${CLIENT_SECRET}'
  fi
fi

generate_config "/credenza/config/oidc_idp_profiles.json.in" \
 "/credenza/config/oidc_idp_profiles.json"

inject_secret /run/secrets/mcp_client_secret DERIVA_MCP_CLIENT_SECRET
if require_envs DERIVA_MCP_CLIENT_SECRET; then
  export HASHED_DERIVA_MCP_CLIENT_SECRET=$(python3 -c \
    "from argon2 import PasswordHasher; import sys; print(PasswordHasher().hash(sys.stdin.read().strip()))" \
    <<< "${DERIVA_MCP_CLIENT_SECRET}")
  generate_config "/credenza/config/client_registry.json.in" "/credenza/config/client_registry.json" \
   '${HASHED_DERIVA_MCP_CLIENT_SECRET}'
fi

# set default command
if [ $# -eq 0 ]; then
  set -- gunicorn --workers 1 --threads 4 --bind 0.0.0.0:8999  --forwarded-allow-ips=127.0.0.1,::1,${RPROXY_IP} credenza.credenza_wsgi:application
fi

# run processes
start_rsyslog
start_main_process "$@"
monitor_loop