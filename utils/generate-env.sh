#!/bin/bash

set -e

# Default values
ENV_TYPE=""
OUTPUT_DIR="${HOME}/.deriva-docker/env"
CUSTOM_HOSTNAME=""
DECORATE_HOSTNAME="false"
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
  --email EMAIL             Let's Encrypt email address (required for dev, staging, prod)
  --cert-filename FILE      Certificate filename (optional)
  --key-filename FILE       Private key filename (optional)
  --ca-filename FILE        CA certificate filename (optional)
  --cert-dir DIR            Certificate base directory (optional)
  --help, -?                Show this help message and exit

Examples:
  $0 -e test -h localhost
  $0 -e all -h mdarcy.at.derivacloud.net
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
    --email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --cert-filename) CERT_FILENAME="$2"; shift 2 ;;
    --key-filename) KEY_FILENAME="$2"; shift 2 ;;
    --ca-filename) CA_FILENAME="$2"; shift 2 ;;
    --cert-dir) CERT_DIR="$2"; shift 2 ;;
    --help|-?) print_help; exit 0 ;;
    *) echo "❌ Unknown option: $1"; echo "Try --help for usage."; exit 1 ;;
  esac
done

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
  DEFAULT_LETSENCRYPT_CERTDIR="\${HOME}/.deriva-docker/certs/\${HOSTNAME}/letsencrypt"
  GRAFANA_USERNAME="deriva-admin"
  GRAFANA_PASSWORD="deriva-admin"
  POSTGRES_PASSWORD="postgres"
  HATRAC_ADMIN_GROUP="admin"
  CREATE_TEST_USERS=false
  CREATE_TEST_DB=false
  COMPOSE_PROFILES=deriva-base,deriva-web-rproxy-letsencrypt,deriva-monitoring-base,deriva-monitoring-rproxy,ddns-update

  case "$ENV" in
    prod)
      POSTGRES_PASSWORD=$(openssl rand -base64 16)
      GRAFANA_PASSWORD=$(openssl rand -base64 16)
      THIRD_OCTET=0
      ;;
    staging)
      POSTGRES_PASSWORD=$(openssl rand -base64 16)
      GRAFANA_PASSWORD=$(openssl rand -base64 16)
      THIRD_OCTET=1
      ;;
    dev)
      POSTGRES_PASSWORD=$(openssl rand -base64 16)
      GRAFANA_PASSWORD=$(openssl rand -base64 16)
      THIRD_OCTET=2
      ;;
    test)
      COMPOSE_PROFILES="deriva-base,deriva-web-rproxy,deriva-monitoring-base,deriva-monitoring-rproxy"
      CREATE_TEST_USERS=true
      CREATE_TEST_DB=true
      THIRD_OCTET=3
      ;;
    basic)
      COMPOSE_PROFILES="deriva-core,deriva-monitoring-base,deriva-monitoring"
      CREATE_TEST_USERS=true
      CREATE_TEST_DB=true
      THIRD_OCTET=4
      ;;
    core)
      COMPOSE_PROFILES="deriva-core"
      CREATE_TEST_USERS=true
      CREATE_TEST_DB=true
      THIRD_OCTET=5
      ;;
  esac


  HOSTNAME="${CUSTOM_HOSTNAME:-$DEFAULT_HOSTNAME}"
  ORG_HOSTNAME=$HOSTNAME
  [[ "$DECORATE_HOSTNAME" == "true" ]] && HOSTNAME="${ENV}-${HOSTNAME}"
  SAFE_HOSTNAME=$(echo "$HOSTNAME" | tr '.-' '_')
  COMPOSE_PROJECT_NAME="deriva-${SAFE_HOSTNAME}"

  SUBNET="172.28.${THIRD_OCTET}.0/24"
  GATEWAY="172.28.${THIRD_OCTET}.1"
  RSYSLOG_IP="172.28.${THIRD_OCTET}.100"
  RPROXY_IP="172.28.${THIRD_OCTET}.250"

  CERT_DIR="${CERT_DIR:-$DEFAULT_CERT_DIR}"
  DEFAULT_CERT_FILENAME="${CERT_DIR}.crt"
  DEFAULT_KEY_FILENAME="${CERT_DIR}.key"
  CERT_FILENAME="${CERT_FILENAME:-$DEFAULT_CERT_FILENAME}"
  KEY_FILENAME="${KEY_FILENAME:-$DEFAULT_KEY_FILENAME}"
  CA_FILENAME="${CA_FILENAME:-$DEFAULT_CA_FILENAME}"
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$DEFAULT_LETSENCRYPT_EMAIL}"
  LETSENCRYPT_CERTDIR="${LETSENCRYPT_CERTDIR:-$DEFAULT_LETSENCRYPT_CERTDIR}"

  mkdir -p "$OUTPUT_DIR"
  ENV_FILE="${OUTPUT_DIR}/$SAFE_HOSTNAME.env"

  if [[ "$ORG_HOSTNAME" == "localhost" ]]; then
    HOSTNAME=$ORG_HOSTNAME
  fi

  cat <<EOF > "$ENV_FILE"
# Auto-generated $(date)

# Compose
COMPOSE_PROFILES=$COMPOSE_PROFILES
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME

# General
DEPLOY_ENV=$ENV
HOSTNAME=$HOSTNAME
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

# Database
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Monitoring
GRAFANA_USERNAME=$GRAFANA_USERNAME
GRAFANA_PASSWORD=$GRAFANA_PASSWORD

# DERIVA
CREATE_TEST_USERS=$CREATE_TEST_USERS
CREATE_TEST_DB=$CREATE_TEST_DB
HATRAC_ADMIN_GROUP=$HATRAC_ADMIN_GROUP
EOF

  echo "🌐  Environment file '$ENV_FILE' has been created."
}

# Set default ENV_TYPE if not provided
if [[ -z "$ENV_TYPE" ]]; then
    ENV_TYPE="test"
fi

# Validate environment type
if [[ "$ENV_TYPE" != "basic" && "$ENV_TYPE" != "test" && "$ENV_TYPE" != "dev" && "$ENV_TYPE" != "staging" && "$ENV_TYPE" != "prod" && "$ENV_TYPE" != "all" && "$ENV_TYPE" != "core" ]]; then
    echo "❌ Invalid environment type: $ENV_TYPE"
    echo "Valid values: basic, test, dev, staging, prod, core, all"
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
  for env in core basic test dev staging prod; do
    generate_env_file "$env"
  done
else
  generate_env_file "$ENV_TYPE"
fi
