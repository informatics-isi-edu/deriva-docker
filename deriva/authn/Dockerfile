FROM deriva/base AS deriva-base

FROM python:3.13-slim AS core

# Copy shared library scripts
COPY --from=deriva-base /usr/local/lib/*.sh /usr/local/lib/

# Install additional dependencies
RUN apt-get update && apt-get install -y \
    git curl rsyslog libsystemd0 --no-install-recommends \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Add rsyslog configuration
COPY config/rsyslog.conf /etc/rsyslog.conf

WORKDIR /

ARG GIT_FETCH=0
ENV GIT_FETCH=${GIT_FETCH}

# Always create the code dest path
RUN mkdir -p /credenza

# Copy whatever is available from local source
COPY src/credenza ./credenza

# Clone only if forced or local files missing
RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./credenza/pyproject.toml" ]; then \
      echo "Cloning source from GitHub..."; \
      rm -rf ./credenza && \
      git clone https://github.com/informatics-isi-edu/credenza.git ./credenza; \
    else \
      echo "Using local credenza directory from build context"; \
    fi

WORKDIR /credenza

RUN pip install --upgrade pip setuptools build \
 && pip install --no-cache-dir gunicorn .

ENV PYTHONPATH=/credenza/credenza
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Default CMD for minimal use
CMD ["gunicorn", "--workers", "1", "--threads", "4", "--bind", "0.0.0.0:8999", "credenza.credenza_wsgi:application"]
