#!/bin/bash
set -e

# Inject secret into environment
POSTGRES_PASSWORD="$(< /run/secrets/postgres_password)"
export POSTGRES_PASSWORD

# Chain to the original entrypoint
exec docker-entrypoint.sh "$@"
