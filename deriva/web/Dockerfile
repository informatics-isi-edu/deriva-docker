# Base: Ubuntu 24.10
FROM ubuntu:24.10

# Set bash as the default shell
SHELL ["/bin/bash", "-c"]

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
# TODO: refactor things run in a virtualenv to get rid of below
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_NO_CACHE_DIR=yes

# Install minimal Apache
RUN apt-get update && apt install -y apache2 &&  \
    groupadd -o -g $(id -g www-data) apache

# Create the postgres user and it's homedir since the client-only package does not do it. Also set UID and GID to match
# the postgres user in the database container for PEER auth.
RUN groupadd -g 999 postgres &&  \
    useradd -u 999 -g 999 -s /bin/bash -d /var/lib/postgresql -r -c "PostgreSQL administrator" postgres &&  \
    mkdir -p /var/lib/postgresql &&  \
    chown -R postgres:postgres /var/lib/postgresql

# Create Deriva users
RUN useradd -m -g root -r secrets
RUN useradd -m -u 991 -g apache -r webauthn
RUN useradd -m -u 992 -g apache -r ermrest
RUN useradd -m -u 993 -g apache -r hatrac
RUN useradd -m -u 994 -g apache -r deriva
RUN useradd -m -u 995 -g apache -r ermresolve
RUN useradd -m -u 1001 isrddev

# Install minimal rsyslog (for legacy logging)
RUN apt-get install -y rsyslog libsystemd0 --no-install-recommends
ADD lib/etc/rsyslog.conf /etc/rsyslog.conf

# Install extra dependencies for backend
RUN apt-get install -y \
    git rsync sudo \
    postgresql-client-16 python3-psycopg2 \
    python3-pip python3-setuptools python3-ply \
    libapache2-mod-wsgi-py3 libcurl4-openssl-dev libjson-c-dev apache2-dev ca-certificates \
    python3-cryptography python3-openssl python3-oauth2client \
    python3-flask python3-requests

# Install extra dependencies for frontend
RUN apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs ruby ruby-dev rubygems
RUN gem install jekyll jekyll-paginate jekyll-scholar jekyll-seo-tag jekyll-redirect-from rdiscount

# Verify installations
RUN node -v && npm -v

# Clean up
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Install additional Deriva configuration and platform management files
ADD lib/etc/isrd-recipe-conf.d /etc/isrd-recipe-conf.d
ADD lib/home /home
ADD lib/var/tmp /var/tmp
ADD lib/usr/local /usr/local
RUN chmod +x /usr/local/sbin/*
RUN . /usr/local/sbin/isrd-recipe-lib.sh && isrd_fixup_permissions

# Install Deriva webservice code from GitHub
RUN isrd-stack-mgmt.sh clone
RUN isrd-stack-mgmt.sh checkout
RUN isrd-stack-mgmt.sh install

ADD lib/var/www/html /var/www/html
RUN . /usr/local/sbin/isrd-recipe-lib.sh && isrd_fixup_permissions /var/www

# Apache setup
ADD lib/etc/apache2 /etc/apache2
RUN a2enmod ssl wsgi rewrite headers remoteip usertrack deflate http2 unique_id
RUN a2enconf wsgi remoteip usertrack deflate http2 status
RUN a2dissite 000-default &&  \
    rm -f /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-enabled/000-default.conf
RUN ln -s /etc/apache2/conf-enabled /etc/apache2/conf.d

# Start Apache in the foreground
CMD ["apachectl", "-D", "FOREGROUND"]
