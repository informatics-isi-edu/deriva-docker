# Base: Ubuntu 24.04 LTS
FROM ubuntu:24.04 AS deriva-web-base
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_NO_CACHE_DIR=yes

# Core runtime deps kept small; cache apt for speed
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      sudo git rsync make \
      rsyslog libsystemd0 \
      postgresql-client-16 python3-psycopg2 \
      python3-pip python3-setuptools python3-ply \
      apache2 libapache2-mod-wsgi-py3 ca-certificates \
      python3-cryptography python3-openssl python3-oauth2client \
      python3-flask python3-requests \
    && rm -rf /var/lib/apt/lists/*

# Match 'apache' group with default
RUN groupadd -o -g $(id -g www-data) apache
# Create the postgres user and it's homedir since the client-only package does not do it.
RUN groupadd -g 999 postgres &&  \
    useradd -u 999 -g 999 -s /bin/bash -r -c "PostgreSQL administrator" postgres
# Create Deriva daemon users
RUN useradd -m -g root -r secrets \
 && useradd -m -u 991 -g apache -s /bin/bash -r webauthn \
 && useradd -m -u 992 -g apache -s /bin/bash -r ermrest \
 && useradd -m -u 993 -g apache -s /bin/bash -r hatrac \
 && useradd -m -u 994 -g apache -s /bin/bash -r deriva \
 && useradd -m -u 995 -g apache -s /bin/bash -r ermresolve \
 && useradd -m -u 996 -g apache -s /bin/bash -r credenza \
 && useradd -m -u 1001 -s /bin/bash isrddev

ADD lib/etc/rsyslog.conf /etc/rsyslog.conf

FROM deriva-web-base AS deriva-web-builder

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      curl ruby ruby-dev build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Required Deriva configuration and util/library files
ADD lib/usr/local /usr/local
ADD lib/etc/isrd-recipe-conf.d /etc/isrd-recipe-conf.d
ADD lib/home /home
RUN chmod +x /usr/local/sbin/*

# Copy shared library scripts
COPY --from=isrddev/deriva-base:latest /usr/local/lib/*.sh /usr/local/lib/

# Source helper + fix permissions as required
RUN . /usr/local/sbin/isrd-recipe-lib.sh && isrd_fixup_permissions

# Speed up pip/npm with persistent caches; ensure isrddev owns its home caches
RUN mkdir -p /home/isrddev && chown -R isrddev: /home/isrddev

# Clone / checkout / install with caches mounted
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/home/isrddev/.npm,uid=1001,gid=1001 \
    --mount=type=cache,target=/home/isrddev/.cache,uid=1001,gid=1001 \
    . /usr/local/sbin/isrd-recipe-lib.sh && \
    isrd-stack-mgmt.sh clone && \
    isrd-stack-mgmt.sh checkout && \
    isrd-stack-mgmt.sh install

# Prune out unnecessary dirs to shrink image size
RUN find / -type d -name ".git" -prune -exec rm -rf {} + || true
RUN find /usr/local -type d -name "__pycache__" -prune -exec rm -rf {} + \
 && find /usr/local -type f -name "*.pyc" -delete


FROM deriva-web-base AS deriva-web

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Bring in only what runtime needs
COPY --from=deriva-web-builder /usr/local /usr/local
COPY --from=deriva-web-builder /etc/isrd-recipe-conf.d  /etc/isrd-recipe-conf.d
COPY --from=deriva-web-builder /var/www/html /var/www/html
COPY --from=deriva-web-builder /home /home

# Optional overlay of additional static content from repo
ADD lib/var/www/html /var/www/html
RUN . /usr/local/sbin/isrd-recipe-lib.sh && isrd_fixup_permissions /var/www

# Optional test database
ADD lib/var/tmp/_ermrest_catalog_1.sql.gz /var/tmp/_ermrest_catalog_1.sql.gz

# Apache setup
ADD lib/etc/apache2 /etc/apache2
RUN a2enmod ssl wsgi rewrite headers remoteip usertrack deflate http2 unique_id && \
    a2enconf wsgi remoteip usertrack deflate http2 status && \
    a2dissite 000-default || true && \
    rm -f /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-enabled/000-default.conf && \
    ln -s /etc/apache2/conf-enabled /etc/apache2/conf.d

# Entrypoint
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh
ENTRYPOINT ["/opt/entrypoint.sh"]

CMD ["apachectl", "-D", "FOREGROUND"]
