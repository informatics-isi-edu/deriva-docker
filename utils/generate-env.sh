#!/bin/bash

set -e

# Default values
ENV_TYPE=""
OUTPUT_DIR="${HOME}/.deriva-docker/env"
CUSTOM_HOSTNAME=""
DECORATE_HOSTNAME="false"
ENABLE_AUTH="false"
ENABLE_KEYCLOAK="false"
ENABLE_GROUPS="false"
ENABLE_DDNS="false"
LETSENCRYPT_EMAIL=""
CERT_FILENAME=""
KEY_FILENAME=""
CA_FILENAME=""
CERT_DIR=""

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Generate a DERIVA environment configuration file for use with docker-compose.

Options:
  --env, -e ENV             Environment type (required): basic | test | dev | staging | prod | core | all
  --output-dir DIR          Output directory for generated env file (default: ~/.deriva-docker/env)
  --hostname, -h NAME       Custom hostname (optional)
  --decorate-hostname, -d   Prepend the environment name to the hostname (e.g. dev-myhost), automatic when using "-e all", except for "localhost"
  --enable-auth, -a         Enable Credenza authentication broker containers
  --enable-keycloak, -k     Enable KeyCloak IDP containers
  --enable-groups, -g       Enable Deriva Groups containers
  --enable-ddns,            Enable DDNS refresh
  --email EMAIL             Let's Encrypt email address (required for dev, staging, prod)
  --cert-filename FILE      Certificate filename (optional)
  --key-filename FILE       Private key filename (optional)
  --ca-filename FILE        CA certificate filename (optional)
  --cert-dir DIR            Certificate base directory (optional)
  --help, -?                Show this help message and exit

Examples:
  $0 -e test -h localhost
  $0 -e all -h test.at.derivacloud.net
  $0 --env dev --hostname myhost.local --email user@example.com --cert-dir ../../deriva-devops/tls/deriva-dev/certs/my-certdir

EOF
}

# Parse named arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env|-e) ENV_TYPE="$2"; shift 2 ;;
    --output-dir|-o) OUTPUT_DIR="$2"; shift 2 ;;
    --hostname) CUSTOM_HOSTNAME="$2"; shift 2 ;;
    -h)
      if [[ -n "$2" && ! "$2" =~ ^- ]]; then CUSTOM_HOSTNAME="$2"; shift 2
      else print_help; exit 0; fi ;;
    --decorate-hostname|-d) DECORATE_HOSTNAME="true"; shift ;;
    --enable-auth|-a) ENABLE_AUTH="true"; shift ;;
    --enable-keycloak|-k) ENABLE_KEYCLOAK="true"; shift ;;
    --enable-groups|-g) ENABLE_GROUPS="true"; shift ;;
    --enable-ddns) ENABLE_DDNS="true"; shift ;;
    --hatrac-admin-group) HATRAC_ADMIN_GROUP="$2"; shift 2 ;;
    --email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --cert-filename) CERT_FILENAME="$2"; shift 2 ;;
    --key-filename) KEY_FILENAME="$2"; shift 2 ;;
    --ca-filename) CA_FILENAME="$2"; shift 2 ;;
    --cert-dir) CERT_DIR="$2"; shift 2 ;;
    --help|-?) print_help; exit 0 ;;
    *) echo "❌ Unknown option: $1"; echo "Try --help for usage."; exit 1 ;;
  esac
done

# Define allowed environment types
VALID_ENV_TYPES=("test" "dev" "staging" "prod" "all" )

# Function to check if a value is in an array
is_valid_env_type() {
    local env="$1"
    for valid in "${VALID_ENV_TYPES[@]}"; do
        [[ "$env" == "$valid" ]] && return 0
    done
    return 1
}

generate_random_string() {
  local length="${1:-16}"

  if ! [[ "$length" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid length: '$length'. Must be a positive integer." >&2
    return 1
  fi

  if (( length < 8 )); then
    echo "❌ Minimum length is 8. Requested: $length" >&2
    return 1
  fi

  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c"$length"
}


SECRET_VARS=()

# Function to generate an environment file
generate_env_file() {
  ENV=$1

  HTTP_PORT=80
  HTTPS_PORT=443
  DEFAULT_HOSTNAME="localhost"
  DEFAULT_CERT_DIR="deriva-dev-localhost"
  DEFAULT_CERT_FILENAME="${DEFAULT_CERT_DIR}.crt"
  DEFAULT_KEY_FILENAME="${DEFAULT_CERT_DIR}.key"
  DEFAULT_CA_FILENAME="deriva-dev-ca.crt"
  DEFAULT_LETSENCRYPT_EMAIL="isrd-support@isi.edu"
  DEFAULT_LETSENCRYPT_CERTDIR="\${HOME}/.deriva-docker/certs/\${CONTAINER_HOSTNAME}/letsencrypt"
  DEFAULT_CREDENZA_ENCRYPTION_KEY=$(generate_random_string 24)
  DEFAULT_KEYCLOAK_DERIVA_CLIENT_SECRET=$(generate_random_string 32)
  DEFAULT_AUTHN_SESSION_HOST=$DEFAULT_HOSTNAME
  DEFAULT_AUTHN_SESSION_HOST_VERIFY=true
  GRAFANA_USERNAME="deriva-admin"
  GRAFANA_PASSWORD="deriva-admin"
  POSTGRES_PASSWORD="postgres"
  CREDENZA_DB_PASSWORD="credenza"
  DEFAULT_HATRAC_ADMIN_GROUP="admin"
  CREATE_TEST_USERS=false
  CREATE_TEST_DB=false
  COMPOSE_PROFILES=deriva-base,deriva-monitoring-base,deriva-monitoring-rproxy

  HOSTNAME="${CUSTOM_HOSTNAME:-$DEFAULT_HOSTNAME}"
  ORG_HOSTNAME=$HOSTNAME
  [[ "$DECORATE_HOSTNAME" == "true" ]] && HOSTNAME="${ENV}-${HOSTNAME}"
  SAFE_HOSTNAME=$(echo "$HOSTNAME" | tr '.-' '_')
  COMPOSE_PROJECT_NAME="deriva-${SAFE_HOSTNAME}"

  if [[ "$ORG_HOSTNAME" == "localhost" ]]; then
    HOSTNAME=$ORG_HOSTNAME
  fi

  DEFAULT_SECRETS_DIR="${OUTPUT_DIR}/secrets/${SAFE_HOSTNAME}"

  # Apply shared logic for prod/staging/dev
  if [[ "$ENV" == "prod" || "$ENV" == "staging" || "$ENV" == "dev" ]]; then
    if  [[ "$ENABLE_AUTH" == "true" ]]; then
      COMPOSE_PROFILES+=",deriva-web-rproxy-letsencrypt,deriva-auth"
      CREDENZA_DB_PASSWORD=$(generate_random_string)
    else
      COMPOSE_PROFILES+=",deriva-web-rproxy-letsencrypt"
    fi
    POSTGRES_PASSWORD=$(generate_random_string)
    GRAFANA_PASSWORD=$(generate_random_string)
    DEFAULT_HATRAC_ADMIN_GROUP="https://auth.globus.org/3938e0d0-ed35-11e5-8641-22000ab4b42b"
  fi

  case "$ENV" in
    prod)
      THIRD_OCTET=0
      COMPOSE_PROFILES+=",prod"
      ;;
    staging)
      THIRD_OCTET=1
      COMPOSE_PROFILES+=",staging"
      ;;
    dev)
      THIRD_OCTET=2
      COMPOSE_PROFILES+=",dev"
      ;;
    test)
      THIRD_OCTET=3
      if  [[ "$ENABLE_AUTH" == "true" ]]; then
        COMPOSE_PROFILES+=",deriva-web-rproxy,deriva-auth,deriva-auth-dev,test"
        ENABLE_KEYCLOAK="true"
        AUTHN_SESSION_HOST="rproxy"
        AUTHN_SESSION_HOST_VERIFY=false
        CREDENZA_REDIS_COMMANDER_PASSWORD="credenza-admin"
      else
        COMPOSE_PROFILES+=",deriva-web-rproxy,test"
      fi
      CREATE_TEST_USERS=true
      CREATE_TEST_DB=true
      ;;
  esac

  [[ "$ENABLE_KEYCLOAK" == "true" && "$ENABLE_AUTH" == "true" ]] && COMPOSE_PROFILES+=",deriva-auth-keycloak"
  [[ "$ENABLE_GROUPS" == "true" ]] && COMPOSE_PROFILES+=",deriva-groups"
  [[ "$ENABLE_DDNS" == "true" ]] && COMPOSE_PROFILES+=",ddns-update"

  SUBNET="172.28.${THIRD_OCTET}.0/24"
  GATEWAY="172.28.${THIRD_OCTET}.1"
  RSYSLOG_IP="172.28.${THIRD_OCTET}.100"
  KEYCLOAK_IP="172.28.${THIRD_OCTET}.200"
  RPROXY_IP="172.28.${THIRD_OCTET}.250"

  CERT_DIR="${CERT_DIR:-$DEFAULT_CERT_DIR}"
  DEFAULT_CERT_FILENAME="${CERT_DIR}.crt"
  DEFAULT_KEY_FILENAME="${CERT_DIR}.key"
  CERT_FILENAME="${CERT_FILENAME:-$DEFAULT_CERT_FILENAME}"
  KEY_FILENAME="${KEY_FILENAME:-$DEFAULT_KEY_FILENAME}"
  CA_FILENAME="${CA_FILENAME:-$DEFAULT_CA_FILENAME}"
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$DEFAULT_LETSENCRYPT_EMAIL}"
  LETSENCRYPT_CERTDIR="${LETSENCRYPT_CERTDIR:-$DEFAULT_LETSENCRYPT_CERTDIR}"
  HATRAC_ADMIN_GROUP="${HATRAC_ADMIN_GROUP:-$DEFAULT_HATRAC_ADMIN_GROUP}"
  AUTHN_SESSION_HOST="${AUTHN_SESSION_HOST:-$DEFAULT_AUTHN_SESSION_HOST}"
  AUTHN_SESSION_HOST_VERIFY="${AUTHN_SESSION_HOST_VERIFY:-$DEFAULT_AUTHN_SESSION_HOST_VERIFY}"
  CREDENZA_DB_PASSWORD="${CREDENZA_DB_PASSWORD:-$DEFAULT_CREDENZA_DB_PASSWORD}"
  CREDENZA_ENCRYPTION_KEY="${CREDENZA_ENCRYPTION_KEY:-$DEFAULT_CREDENZA_ENCRYPTION_KEY}"
  KEYCLOAK_DERIVA_CLIENT_SECRET="${KEYCLOAK_DERIVA_CLIENT_SECRET:-$DEFAULT_KEYCLOAK_DERIVA_CLIENT_SECRET}"
  SECRETS_DIR="${SECRETS_DIR:-$DEFAULT_SECRETS_DIR}"

  # Build up the set of secret variables to emit to files
  SECRET_VARS=()
  # Always include core secrets
  SECRET_VARS+=(
    GRAFANA_PASSWORD
    POSTGRES_PASSWORD
  )
  # Auth secrets
  if  [[ "$ENABLE_AUTH" == "true" ]]; then
    SECRET_VARS+=(
      CREDENZA_DB_PASSWORD
      CREDENZA_ENCRYPTION_KEY
    )
    [[ "$ENV" == "test" ]] && SECRET_VARS+=(CREDENZA_REDIS_COMMANDER_PASSWORD)
  fi
  # Keycloak secrets
  if [[ "$ENABLE_KEYCLOAK" == "true" && "$ENABLE_AUTH" == "true" ]]; then
    SECRET_VARS+=(
      KEYCLOAK_DERIVA_CLIENT_SECRET
    )
  fi

  mkdir -p "$OUTPUT_DIR"
  ENV_FILE="${OUTPUT_DIR}/$SAFE_HOSTNAME.env"

  cat <<EOF > "$ENV_FILE"
# Auto-generated $(date)

# Compose
COMPOSE_PROFILES=$COMPOSE_PROFILES
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME

# General
DEPLOY_ENV=$ENV
CONTAINER_HOSTNAME=$HOSTNAME
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
LETSENCRYPT_CERTDIR=$LETSENCRYPT_CERTDIR

# Networking
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
SUBNET=$SUBNET
GATEWAY=$GATEWAY
RSYSLOG_IP=$RSYSLOG_IP
RPROXY_IP=$RPROXY_IP

# SSL Certificates
CERT_FILENAME=$CERT_FILENAME
KEY_FILENAME=$KEY_FILENAME
CA_FILENAME=$CA_FILENAME
CERT_DIR=$CERT_DIR

# Auth
AUTHN_SESSION_HOST=$AUTHN_SESSION_HOST
AUTHN_SESSION_HOST_VERIFY=$AUTHN_SESSION_HOST_VERIFY
KEYCLOAK_IP=${KEYCLOAK_IP}

# Database
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Monitoring
GRAFANA_USERNAME=$GRAFANA_USERNAME
GRAFANA_PASSWORD=$GRAFANA_PASSWORD

# DERIVA
CREATE_TEST_USERS=$CREATE_TEST_USERS
CREATE_TEST_DB=$CREATE_TEST_DB
HATRAC_ADMIN_GROUP=$HATRAC_ADMIN_GROUP

# Secrets
SECRETS_DIR=$SECRETS_DIR

EOF
  echo "🌐  Environment file '$ENV_FILE' has been created."
}

# Emit one or more env vars to individual files under a base directory, with .txt suffix.
# Usage: emit_envs_to_files VAR1 [VAR2 ...] BASE_PATH
emit_envs_to_files() {
  if [[ $# -lt 2 ]]; then
    echo "❌ Usage: emit_envs_to_files VAR1 [VAR2 ...] BASE_PATH"
    return 1
  fi

  local base_path="${@: -1}"  # Last argument
  local vars=("${@:1:$#-1}")  # All but last argument

  if [[ ! -d "$base_path" ]]; then
    mkdir -p "$base_path" || {
      echo "❌ Failed to create base path: $base_path"
      return 1
    }
  fi

  for var_name in "${vars[@]}"; do
    local value="${!var_name}"
    local lower_name
    lower_name="$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    local dest_path="${base_path}/${lower_name}.txt"

    if [[ -z "$value" ]]; then
      echo "⚠️ Skipping unset or empty env var: $var_name"
      continue
    fi

    echo -n "$value" > "$dest_path"
    echo "✅ Wrote \$$var_name to $dest_path"
  done
}


# Set default ENV_TYPE if not provided
if [[ -z "$ENV_TYPE" ]]; then
    ENV_TYPE="test"
    ENABLE_AUTH="true"
fi

# Validate environment type
if ! is_valid_env_type "$ENV_TYPE"; then
    echo "❌ Invalid environment type: $ENV_TYPE"
    echo "Valid values: ${VALID_ENV_TYPES[*]}"
    exit 1
fi

# Require email for certain environments
if [[ "$ENV_TYPE" != "all" && ("$ENV_TYPE" == "prod" || "$ENV_TYPE" == "staging" || "$ENV_TYPE" == "dev") && -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "❌ Missing required --email for environment: $ENV_TYPE"
  echo "Please provide a valid email address for Let's Encrypt account registration."
  exit 1
fi


if [[ "$ENV_TYPE" == "all" ]]; then
  DECORATE_HOSTNAME="true"
  for env in test dev staging prod; do
    generate_env_file "$env"
    emit_envs_to_files "${SECRET_VARS[@]}" "${SECRETS_DIR}/${env}"
  done
else
  generate_env_file "$ENV_TYPE"
  emit_envs_to_files "${SECRET_VARS[@]}" "${SECRETS_DIR}/${ENV_TYPE}"
fi
