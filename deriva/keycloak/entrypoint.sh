#!/bin/bash
set -e

source /usr/local/lib/utils.sh

# Inject secret from file into env var
inject_secret run/secrets/keycloak_deriva_client_secret KEYCLOAK_DERIVA_CLIENT_SECRET

# Ensure target directory exists
mkdir -p /opt/keycloak/data/import/

# Apply the combined sed expression to the template
if [[ ! -f /opt/keycloak/data/import/realm-export.json ]]; then
  substitute_env_vars /opt/realm-export.json.in /opt/keycloak/data/import/realm-export.json
fi

# Execute the normal Keycloak entrypoint
exec /opt/keycloak/bin/kc.sh "$@"
