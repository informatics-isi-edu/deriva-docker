#!/bin/bash
set -e

echo "🌐   Current deployment environment: $DEPLOY_ENV"

# Clean up stale rsyslog PID file (if it exists) and exec rsyslog
if [ -f /run/rsyslogd.pid ]; then
  rm -f /run/rsyslogd.pid
fi
exec rsyslogd -n &

. /usr/local/sbin/isrd-recipe-lib.sh

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
    # Deal with possible alternate ports in webauthn ClientSessionCachedProxy config
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" /home/ermrest/ermrest_config.json
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" /home/hatrac/hatrac_config.json
    isrd-stack-mgmt.sh deploy
    isrd_fixup_permissions /var/www

    # Configure Apache vhost ports
    envsubst '${APACHE_HTTP_PORT} ${APACHE_HTTPS_PORT}' < /etc/apache2/sites-available/http-redirect.conf.template \
     > /etc/apache2/sites-available/http-redirect.conf
    envsubst '${APACHE_HTTPS_PORT}' < /etc/apache2/sites-available/default-ssl.conf.template \
     > /etc/apache2/sites-available/default-ssl.conf
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

    # Disable legacy mod_webauthn
    a2dismod -q webauthn
    rm -f /etc/apache2/conf.d/webauthn.conf

    touch "$DEPLOYMENT_MARKER_FILE"
    echo "✅   Deriva software deployment complete."
else
    echo "✅   Skipping Deriva software deployment steps; already installed."
fi

TESTENV_MARKER_FILE="/home/isrddev/.testenv-deployed"
if [ ! -f "$TESTENV_MARKER_FILE" ]; then

    if [[ "$CREATE_TEST_USERS" == "true" ]]; then
      echo "🔧   Creating test users..."
      sudo -H -u webauthn webauthn2-manage adduser deriva-admin
      sudo -H -u webauthn webauthn2-manage passwd deriva-admin deriva-admin
      sudo -H -u webauthn webauthn2-manage addattr admin
      sudo -H -u webauthn webauthn2-manage assign deriva-admin admin
      sudo -H -u webauthn webauthn2-manage adduser deriva
      sudo -H -u webauthn webauthn2-manage passwd deriva deriva
    fi

    if [[ "$CREATE_TEST_DB" == "true" ]]; then
      echo "🔧   Restoring test catalog..."
      dbname="${TEST_DBNAME:-"_ermrest_catalog_1"}"
      isrd_restore_db ermrest ermrest "${dbname}" "/var/tmp/${dbname}.sql.gz"
      isrd_insert_ermrest_registry "${dbname}"
    fi

    touch "$TESTENV_MARKER_FILE"
    echo "✅   Test environment deployment complete."
else
    echo "✅   Skipping test environment deployment steps; already installed."
fi

source /etc/apache2/envvars
exec apache2 -DFOREGROUND


