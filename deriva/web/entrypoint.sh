#!/bin/bash
set -e

echo "🌐   Current deployment environment: $DEPLOY_ENV"

# Clean up stale rsyslog PID file (if it exists) and exec rsyslog
if [ -f /run/rsyslogd.pid ]; then
  rm -f /run/rsyslogd.pid
fi
exec rsyslogd -n &

. /usr/local/sbin/isrd-recipe-lib.sh
. /usr/local/lib/utils.sh

CERT_PATH="/certs-ext/${CERT_DIR}/${CERT_FILENAME}"
KEY_PATH="/certs-ext/${CERT_DIR}/${KEY_FILENAME}"
CERT_CA_PATH="/certs-ext/${CA_FILENAME}"
SYSTEM_CERT_PATH="/etc/ssl/certs/deriva.crt"
SYSTEM_KEY_PATH="/etc/ssl/private/deriva.key"
SYSTEM_CA_CERT_PATH="/usr/local/share/ca-certificates/${CA_FILENAME}"

# Install external certs - if not present, generate a self-signed cert on the fly
if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
  CERT_PATH="/certs/deriva.crt"
  KEY_PATH="/certs/deriva.key"
  if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    echo "🔧   Generating self-signed TLS certificate..."
    # Step 1: Generate RSA private key quietly
    openssl genrsa -out $KEY_PATH 4096 2>/dev/null

    # Step 2: Generate self-signed cert
    openssl req -new -x509 \
      -key "$KEY_PATH" \
      -out "$CERT_PATH" \
      -days 365 \
      -subj "/CN=${HOSTNAME}" \
      -addext "subjectAltName=DNS:${HOSTNAME}" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=keyCertSign,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth"

    chmod 644 $CERT_PATH
    chown root:root $CERT_PATH
    chmod 600 $KEY_PATH
    chown root:root $KEY_PATH

    echo "✅   TLS certificate generated successfully."
  fi
fi


echo "🔧   Installing/Updating TLS certificate..."
cp $CERT_PATH $SYSTEM_CERT_PATH
chmod 644 $SYSTEM_CERT_PATH
chown root:root $SYSTEM_CERT_PATH
cp $KEY_PATH $SYSTEM_KEY_PATH
chmod 600 $SYSTEM_KEY_PATH
chown root:root $SYSTEM_KEY_PATH

# Inject ServerName into Apache config if provided
if [[ -n "$HOSTNAME" ]]; then
    echo "ServerName $HOSTNAME" > /etc/apache2/conf-enabled/servername.conf
fi

DEPLOYMENT_MARKER_FILE="/var/run/.deriva-stack-deployed"
if [ ! -f "$DEPLOYMENT_MARKER_FILE" ]; then

    echo "🔧   Deploying Deriva stack..."
    export ENV PIP_NO_CACHE_DIR=yes

    # Inject required secrets into environment
    inject_secret /run/secrets/postgres_password POSTGRES_PASSWORD
    inject_secret /run/secrets/postgres_ermrest_password POSTGRES_ERMREST_PASSWORD
    inject_secret /run/secrets/postgres_hatrac_password POSTGRES_HATRAC_PASSWORD
    inject_secret /run/secrets/postgres_deriva_password POSTGRES_DERIVA_PASSWORD
    inject_secret /run/secrets/postgres_webauthn_password POSTGRES_WEBAUTHN_PASSWORD
    inject_secret /run/secrets/postgres_credenza_password POSTGRES_CREDENZA_PASSWORD

    # Configure Postgres user account and connection
    if require_envs POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD; then
      substitute_env_vars "/home/postgres/.bash_profile.in" "/home/postgres/.bash_profile" '${POSTGRES_HOST}'
      substitute_env_vars "/home/postgres/.pgpass.in" "/home/postgres/.pgpass" \
       '${POSTGRES_HOST} ${POSTGRES_USER} ${POSTGRES_PASSWORD}'
      chown postgres:postgres /home/postgres/.*
      chmod 0600 /home/postgres/.pgpass
    else
      exit 1
    fi

    # Create DERIVA Postgres DB roles via postgres user
    sudo -iu postgres env \
     POSTGRES_ERMREST_PASSWORD=${POSTGRES_ERMREST_PASSWORD} \
     POSTGRES_HATRAC_PASSWORD=${POSTGRES_HATRAC_PASSWORD} \
     POSTGRES_WEBAUTHN_PASSWORD=${POSTGRES_WEBAUTHN_PASSWORD} \
     POSTGRES_DERIVA_PASSWORD=${POSTGRES_DERIVA_PASSWORD} \
     POSTGRES_CREDENZA_PASSWORD=${POSTGRES_CREDENZA_PASSWORD} \
     "create-db-roles.sh"

    # Configure ERMRest
    substitute_env_vars "/home/ermrest/ermrest_config.json.in" \
     "/home/ermrest/ermrest_config.json" \
      '${POSTGRES_HOST} ${ERMREST_ADMIN_GROUP} ${AUTHN_SESSION_HOST} ${AUTHN_SESSION_HOST_VERIFY}'
    substitute_env_vars "/home/ermrest/.bash_profile.in" "/home/ermrest/.bash_profile" '${POSTGRES_HOST}'
    substitute_env_vars "/home/ermrest/.pgpass.in" "/home/ermrest/.pgpass" \
     '${POSTGRES_HOST} ${POSTGRES_ERMREST_PASSWORD}'
    chown ermrest /home/ermrest/.*
    chmod 0600 /home/ermrest/.pgpass

    # Configure Hatrac
    substitute_env_vars "/home/hatrac/hatrac_config.json.in" "/home/hatrac/hatrac_config.json" \
     '${POSTGRES_HOST} ${AUTHN_SESSION_HOST} ${AUTHN_SESSION_HOST_VERIFY}'
    substitute_env_vars "/home/hatrac/.bash_profile.in" "/home/hatrac/.bash_profile" '${POSTGRES_HOST}'
    substitute_env_vars "/home/hatrac/.pgpass.in" "/home/hatrac/.pgpass" \
     '${POSTGRES_HOST} ${POSTGRES_HATRAC_PASSWORD}'
    chown hatrac /home/hatrac/.*
    chmod 0600 /home/hatrac/.pgpass

    # Configure Webauthn -> Postgres connection (temp until webauthn removed from build)
    substitute_env_vars "/home/webauthn/webauthn2_config.json.in" "/home/webauthn/webauthn2_config.json" \
     '${POSTGRES_HOST} ${POSTGRES_WEBAUTHN_PASSWORD}'

    # Configure Credenza
    mkdir -p /home/credenza/secrets
    chown credenza /home/credenza/secrets
    inject_secret /run/secrets/credenza_db_password CREDENZA_DB_PASSWORD
    inject_secret /run/secrets/credenza_encryption_key CREDENZA_ENCRYPTION_KEY
    inject_secret /run/secrets/keycloak_deriva_client_secret KEYCLOAK_CLIENT_SECRET
    if require_envs POSTGRES_HOST POSTGRES_CREDENZA_PASSWORD; then
      substitute_env_vars "/home/credenza/.pgpass.in" "/home/credenza/.pgpass" \
       '${POSTGRES_HOST} ${POSTGRES_CREDENZA_PASSWORD}'
      chown credenza /home/credenza/.pgpass
      chmod 0600 /home/credenza/.pgpass
    fi
    if require_envs KEYCLOAK_CLIENT_SECRET; then
      export CLIENT_ID=${KEYCLOAK_CLIENT_ID:-"deriva-client"} CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}
      CLIENT_SECRET_FILE_IN="/home/credenza/config/template_client_secret.json.in"
      CLIENT_SECRET_FILE_OUT="/home/credenza/secrets/keycloak_client_secret.json"
      substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
       '${CLIENT_ID} ${CLIENT_SECRET}'
    fi
    if require_envs OKTA_CLIENT_ID OKTA_CLIENT_SECRET; then
      export CLIENT_ID=${OKTA_CLIENT_ID} CLIENT_SECRET=${OKTA_CLIENT_SECRET}
      CLIENT_SECRET_FILE_IN="/home/credenza/config/template_client_secret.json.in"
      CLIENT_SECRET_FILE_OUT="/home/credenza/secrets/okta_client_secret.json"
      substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
       '${CLIENT_ID} ${CLIENT_SECRET}'
    fi
    if require_envs COGNITO_CLIENT_ID COGNITO_CLIENT_SECRET COGNITO_NATIVE_CLIENT_ID; then
      export CLIENT_ID=${COGNITO_CLIENT_ID} CLIENT_SECRET=${COGNITO_CLIENT_SECRET} NATIVE_CLIENT_ID=${COGNITO_NATIVE_CLIENT_ID}
      CLIENT_SECRET_FILE_IN="/home/credenza/config/template_client_secret_native.json.in"
      CLIENT_SECRET_FILE_OUT="/home/credenza/secrets/cognito_client_secret.json"
      substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
       '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
    fi
    if require_envs GLOBUS_CLIENT_ID GLOBUS_CLIENT_SECRET GLOBUS_NATIVE_CLIENT_ID; then
      export CLIENT_ID=${GLOBUS_CLIENT_ID} CLIENT_SECRET=${GLOBUS_CLIENT_SECRET} NATIVE_CLIENT_ID=${GLOBUS_NATIVE_CLIENT_ID}
      CLIENT_SECRET_FILE_IN="/home/credenza/config/template_client_secret_native.json.in"
      CLIENT_SECRET_FILE_OUT="/home/credenza/secrets/globus_client_secret.json"
      substitute_env_vars ${CLIENT_SECRET_FILE_IN} ${CLIENT_SECRET_FILE_OUT} \
       '${CLIENT_ID} ${CLIENT_SECRET} ${NATIVE_CLIENT_ID}'
    fi
    substitute_env_vars "/home/credenza/config/oidc_idp_profiles.json.in" \
     "/home/credenza/config/oidc_idp_profiles.json"

    su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='credenza'\"" | grep -q 1 \
     || su - postgres -c "createdb -O credenza credenza"

    # Deal with possible alternate ports in webauthn ClientSessionCachedProxy config
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" \
     /home/ermrest/ermrest_config.json
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" \
     /home/hatrac/hatrac_config.json
    isrd-stack-mgmt.sh deploy
    isrd_fixup_permissions /var/www

    # Configure Apache vhost ports
    substitute_env_vars /etc/apache2/sites-available/http-redirect.conf.template \
     /etc/apache2/sites-available/http-redirect.conf '${APACHE_HTTP_PORT} ${APACHE_HTTPS_PORT}'
    substitute_env_vars /etc/apache2/sites-available/default-ssl.conf.template \
     /etc/apache2/sites-available/default-ssl.conf '${APACHE_HTTPS_PORT}'
    # Also need to replace Listen 80 and 443 lines in /etc/apache2/ports.conf to match vhosts entries
    sed -i \
      -e "s/^\s*Listen\s\+80\b/Listen ${APACHE_HTTP_PORT}/" \
      -e "s/^\s*Listen\s\+443\b/Listen ${APACHE_HTTPS_PORT}/" \
      /etc/apache2/ports.conf

    # Enable vhosts based on deployment
    if [[ "$DEPLOY_ENV" == "core" || "$DEPLOY_ENV" == "basic" ]]; then
      a2ensite -q default-ssl http-redirect
    else
      a2ensite -q default-ssl
    fi

    # Update local CA certificate store based on what internal cert is being used
    if [ -f "$CERT_CA_PATH" ]; then
        echo "🔧  Installing external CA certificate and updating local trust store..."
        # Install CA certificate so that internal SSL requests do not get rejected
        cp $CERT_CA_PATH $SYSTEM_CA_CERT_PATH
        update-ca-certificates
    else
        echo "🔧  Installing self-signed certificate to local trust store..."
        # Just add our self-signed fallback certificate so that internal SSL requests do not get rejected
        cp $CERT_PATH $SYSTEM_CA_CERT_PATH
        update-ca-certificates
    fi

    # unset secrets in env that are no longer needed
    unset POSTGRES_PASSWORD POSTGRES_ERMREST_PASSWORD POSTGRES_HATRAC_PASSWORD \
     POSTGRES_DERIVA_PASSWORD POSTGRES_WEBAUTHN_PASSWORD POSTGRES_CREDENZA_PASSWORD
    unset CREDENZA_DB_PASSWORD CREDENZA_ENCRYPTION_KEY
    unset CLIENT_ID CLIENT_SECRET KEYCLOAK_CLIENT_SECRET
    unset GLOBUS_CLIENT_ID GLOBUS_CLIENT_SECRET GLOBUS_NATIVE_CLIENT_ID
    unset COGNITO_CLIENT_ID COGNITO_CLIENT_SECRET COGNITO_NATIVE_CLIENT_ID
    unset OKTA_CLIENT_ID OKTA_CLIENT_SECRET

    touch "$DEPLOYMENT_MARKER_FILE"
    echo "✅   Deriva software deployment complete."
else
    echo "✅   Skipping Deriva software deployment steps; already installed."
fi

TESTENV_MARKER_FILE="/home/isrddev/.testenv-deployed"
if [ ! -f "$TESTENV_MARKER_FILE" ]; then

    if [[ "$CREATE_TEST_DB" == "true" ]]; then
      echo "🔧   Restoring test catalog..."
      dbname="${TEST_DBNAME:-"_ermrest_catalog_1"}"
      su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${dbname}'\"" | grep -q 1 \
       || isrd_restore_db ermrest ermrest "${dbname}" "/var/tmp/${dbname}.sql.gz" && \
        isrd_insert_ermrest_registry "${dbname}" "${POSTGRES_HOST}"
    fi

    touch "$TESTENV_MARKER_FILE"
    echo "✅   Test environment deployment complete."
else
    echo "✅   Skipping test environment deployment steps; already installed."
fi

# Suppress cert verify warnings for 'localhost', generated by inter-service communication when cert verify is disabled
export PYTHONWARNINGS="ignore:Unverified HTTPS request is being made to host 'localhost'."

exec apache2ctl -D FOREGROUND
