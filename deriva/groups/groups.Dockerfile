FROM python:3.13-slim AS core

COPY --from=isrddev/deriva-base:latest /usr/local/lib/*.sh /usr/local/lib/

RUN apt-get update && apt-get install -y \
    git curl rsyslog libsystemd0 --no-install-recommends \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY config/rsyslog.conf /etc/rsyslog.conf

WORKDIR /

ARG GIT_FETCH=0
ENV GIT_FETCH=${GIT_FETCH}

# Always create the code dest path
RUN mkdir -p /deriva-groups

# Copy whatever is available from local source
COPY src/deriva-groups ./deriva-groups

# Clone only if forced or local files missing
RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./deriva-groups/pyproject.toml" ]; then \
      echo "Cloning source from GitHub..."; \
      rm -rf ./deriva-groups && \
      git clone https://github.com/informatics-isi-edu/deriva-groups.git ./deriva-groups; \
    else \
      echo "Using local deriva-groups directory from build context"; \
    fi

WORKDIR /deriva-groups
RUN pip install --upgrade pip setuptools build \
 && pip install --no-cache-dir gunicorn .

ENV PYTHONPATH=/deriva-groups/deriva
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

CMD ["gunicorn", "--workers", "1", "--threads", "4", "--bind", "0.0.0.0:8999", "deriva.web.groups.wsgi:application"]
