# deriva-mcp-ui
# Multi-stage build for smaller final image.
#
# Build context: deriva-docker/deriva/mcp-ui/
# Local source: place deriva-mcp-ui checkout under src/deriva-mcp-ui/
# If src/deriva-mcp-ui/pyproject.toml is absent or GIT_FETCH=1, source is
# cloned from GitHub at build time.

# Build stage: install dependencies into an isolated venv
FROM python:3.13-slim AS builder

WORKDIR /

ARG GIT_FETCH=0
ARG DERIVA_MCP_UI_GIT_BRANCH=main
ENV GIT_FETCH=${GIT_FETCH}
ENV DERIVA_MCP_UI_GIT_BRANCH=${DERIVA_MCP_UI_GIT_BRANCH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

RUN mkdir -p /deriva-mcp-ui

COPY src/deriva-mcp-ui ./deriva-mcp-ui

RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./deriva-mcp-ui/pyproject.toml" ]; then \
      echo "Cloning source from GitHub (branch: ${DERIVA_MCP_UI_GIT_BRANCH})..."; \
      rm -rf ./deriva-mcp-ui && \
      git clone --branch "${DERIVA_MCP_UI_GIT_BRANCH}" \
        https://github.com/informatics-isi-edu/deriva-mcp-ui.git ./deriva-mcp-ui; \
    else \
      echo "Using local deriva-mcp-ui directory from build context"; \
    fi

WORKDIR /deriva-mcp-ui

ENV UV_PROJECT_ENVIRONMENT=/opt/venv
RUN uv sync --frozen --no-dev --no-editable


# Runtime stage: minimal image with only what the server needs to run
FROM python:3.13-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    rsyslog \
    && rm -rf /var/lib/apt/lists/*

# Shared shell utilities from the deriva base image.
# Provides: inject_secret, substitute_env_vars, start_rsyslog, start_main_process, monitor_loop
COPY --from=isrddev/deriva-base:latest /usr/local/lib/*.sh /usr/local/lib/

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY config/rsyslog.conf /etc/rsyslog.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["deriva-mcp-ui"]

LABEL org.opencontainers.image.title="deriva-mcp-ui"
LABEL org.opencontainers.image.description="Browser-based chatbot UI for the DERIVA platform"
LABEL org.opencontainers.image.licenses="Apache-2.0"