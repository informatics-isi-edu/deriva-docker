FROM deriva/base AS deriva-base

FROM python:3.13-slim AS core

# Copy shared library scripts
COPY --from=isrddev/deriva-base:latest /usr/local/lib/*.sh /usr/local/lib/

# Install additional dependencies
RUN apt-get update && apt-get install -y \
    git curl rsyslog libsystemd0 --no-install-recommends \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Add rsyslog configuration
COPY config/rsyslog.conf /etc/rsyslog.conf

WORKDIR /

ARG GIT_FETCH=0
ARG CREDENZA_GIT_BRANCH=main
ENV GIT_FETCH=${GIT_FETCH}
ENV CREDENZA_GIT_BRANCH=${CREDENZA_GIT_BRANCH}

# Always create the code dest path
RUN mkdir -p /credenza

# Copy whatever is available from local source
COPY src/credenza ./credenza

# Clone only if forced or local files missing
RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./credenza/pyproject.toml" ]; then \
      echo "Cloning source from GitHub (branch: ${CREDENZA_GIT_BRANCH})..."; \
      rm -rf ./credenza && \
      git clone --branch "${CREDENZA_GIT_BRANCH}" \
        https://github.com/informatics-isi-edu/credenza.git ./credenza; \
    else \
      echo "Using local credenza directory from build context"; \
    fi


WORKDIR /credenza

RUN pip install --upgrade pip setuptools build \
 && pip install --no-cache-dir gunicorn .

ENV PYTHONPATH=/credenza/credenza
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Config templates -- copied to two locations:
#   /credenza/config/          working directory (may be bind-mounted by operator)
#   /credenza/config-defaults/ read-only seed; entrypoint copies missing files
#                              from here into /credenza/config/ on startup
COPY config/ /credenza/config/
COPY config/ /credenza/config-defaults/

# Entrypoint
COPY credenza-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
