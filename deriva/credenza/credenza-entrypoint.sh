#!/bin/bash
set -e

source /usr/local/lib/utils.sh
source /usr/local/lib/runtime.sh

# Suppress cert verify warnings in test environments
if [[ "$DEPLOY_ENV" != "prod" && "$DEPLOY_ENV" != "staging" && "$DEPLOY_ENV" != "dev" ]]; then
  export PYTHONWARNINGS="ignore:Unverified HTTPS request"
fi

# inject secrets into env
inject_secret /run/secrets/credenza_db_password CREDENZA_DB_PASSWORD
inject_secret /run/secrets/credenza_encryption_key CREDENZA_ENCRYPTION_KEY
inject_secret /run/secrets/keycloak_deriva_client_secret KEYCLOAK_CLIENT_SECRET

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
if require_envs COGNITO_CLIENT_ID COGNITO_CLIENT_SECRET COGNITO_NATIVE_CLIENT_ID; then
  export CLIENT_ID=${COGNITO_CLIENT_ID} CLIENT_SECRET=${COGNITO_CLIENT_SECRET} NATIVE_CLIENT_ID=${COGNITO_NATIVE_CLIENT_ID}
  CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret_native.json.in"
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/cognito_client_secret.json"
  substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
   '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
fi
if require_envs GLOBUS_CLIENT_ID GLOBUS_CLIENT_SECRET GLOBUS_NATIVE_CLIENT_ID; then
  export CLIENT_ID=${GLOBUS_CLIENT_ID} CLIENT_SECRET=${GLOBUS_CLIENT_SECRET} NATIVE_CLIENT_ID=${GLOBUS_NATIVE_CLIENT_ID}
  CLIENT_SECRET_FILE_IN="/credenza/config/template_client_secret_native.json.in"
  CLIENT_SECRET_FILE_OUT="/credenza/secrets/globus_client_secret.json"
  substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
   '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
fi
substitute_env_vars "/credenza/config/oidc_idp_profiles.json.in" \
 "/credenza/config/oidc_idp_profiles.json"


# set default command
if [ $# -eq 0 ]; then
  set -- gunicorn --workers 1 --threads 4 --bind 0.0.0.0:8999 credenza.credenza_wsgi:application
fi

# run processes
start_rsyslog
start_main_process "$@"
monitor_loop