############## cantaloupe tasks

cantaloupe_fetch()
{
    DIR="/home/${DEVUSER}/cantaloupe"
    URL=${1:-"https://github.com/cantaloupe-project/cantaloupe/releases/download/v4.1.7/cantaloupe-4.1.7.zip"}
    FILENAME=$(basename $URL)
    require mkdir -p "$DIR"
    require cd "$DIR"
    # fetch and (lightly) verify cantaloupe application bundle
    require curl -L "$URL" -o "$FILENAME" -s
    require unzip -qq -t "${FILENAME}"
}

cantaloupe_install()
{
    USER=cantaloupe
    DIR=/home/${DEVUSER}/cantaloupe
    CANTALOUPE=${1:-"cantaloupe-4.1.7"}
    CANTALOUPE_ZIP="${DIR}/${CANTALOUPE}.zip"
    INSTALL_DIR="/usr/local/share/applications"
    # install cantaloupe application files
    require test -r "$CANTALOUPE_ZIP"
    require test -d "$INSTALL_DIR"
    require cd "$INSTALL_DIR"
    require unzip -n -qq "$CANTALOUPE_ZIP"
    require restorecon -r "${INSTALL_DIR}/${CANTALOUPE}"
}

cantaloupe_systemd_service()
{
    CANTALOUPE=${1:-"cantaloupe-4.1.7"}
    MAXMEM=${2:-"8g"}
    USER="cantaloupe"
    JAR="/usr/local/share/applications/${CANTALOUPE}/${CANTALOUPE}.war"
    require test -r "$JAR"
    require test -d /etc/systemd/system
    cat > /etc/systemd/system/cantaloupe.service <<EOF
[Unit]
Description=Cantaloupe Image Server (${CANTALOUPE})

[Service]
User=${USER}
ExecStart=/usr/bin/java -Dcantaloupe.config=/home/${USER}/cantaloupe.properties -Xmx${MAXMEM} -jar ${JAR}
RestartSec=60
Restart=always
KillMode=mixed
TimeoutStopSec=60
Nice=19
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target

EOF
}

cantaloupe_httpd_reverseproxy()
{
    cat > /etc/httpd/conf.d/cantaloupe.conf <<EOF
# Reverse proxy of cantaloupe imaging server /iiif interface
ProxyPass /iiif http://localhost:8182/iiif nocanon
ProxyPassReverse /iiif http://localhost:8182/iiif

EOF
}

cantaloupe_deploy()
{
    # setup cantaloupe home dir
    USER="cantaloupe"
    id "$USER" || require useradd --create-home --system "$USER"
    require chmod og+rx "/home/${USER}"
    require test -r "/home/${USER}/cantaloupe.properties"
    require set_selinux_type httpd_sys_content_t "/home/${USER}/cantaloupe.properties"
    require restorecon -r "/home/${USER}"

    # setup cantaloupe web root and temp dir
    WEB_ROOT="/var/www"
    TEMP_DIR="${WEB_ROOT}/${USER}/tmp"
    require test -d "$WEB_ROOT"
    require mkdir -p "$TEMP_DIR"
    require chown -R ${USER}: "${WEB_ROOT}/${USER}"
    require restorecon -r "$TEMP_DIR"

    # create cantaloupe serivce unit
    require cantaloupe_systemd_service
    require systemctl enable cantaloupe.service
    require systemctl start cantaloupe.service

    # add cantaloupe reverse proxy configuration
    require cantaloupe_httpd_reverseproxy
}
