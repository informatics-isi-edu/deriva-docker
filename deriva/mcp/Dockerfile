# deriva-mcp-core
# Multi-stage build for smaller final image.
#
# Build context: deriva-docker/deriva/mcp/
# Local source: place deriva-mcp-core checkout under src/deriva-mcp-core/
# If src/deriva-mcp-core/pyproject.toml is absent or GIT_FETCH=1, source is
# cloned from GitHub at build time.

# Build stage: install dependencies into an isolated venv
FROM python:3.13-slim AS builder

WORKDIR /

ARG GIT_FETCH=0
ARG DERIVA_MCP_CORE_GIT_BRANCH=main
# Space-separated list of extra packages to install into the venv alongside
# deriva-mcp-core. Use this to add plugins that declare the
# deriva_mcp.plugins entry point. Each entry is passed directly to
# "uv pip install", so git URLs, PyPI specs, and local paths all work:
#   EXTRA_PACKAGES="deriva-ml-mcp@git+https://github.com/org/deriva-ml-mcp.git"
#   EXTRA_PACKAGES="my-plugin>=1.0 another-plugin==2.3"
ARG EXTRA_PACKAGES=""
ENV GIT_FETCH=${GIT_FETCH}
ENV DERIVA_MCP_CORE_GIT_BRANCH=${DERIVA_MCP_CORE_GIT_BRANCH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

RUN mkdir -p /deriva-mcp-core

# Copy whatever is available from local source
COPY src/deriva-mcp-core ./deriva-mcp-core

# Clone only if forced or local files missing
RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./deriva-mcp-core/pyproject.toml" ]; then \
      echo "Cloning source from GitHub (branch: ${DERIVA_MCP_CORE_GIT_BRANCH})..."; \
      rm -rf ./deriva-mcp-core && \
      git clone --branch "${DERIVA_MCP_CORE_GIT_BRANCH}" \
        https://github.com/informatics-isi-edu/deriva-mcp-core.git ./deriva-mcp-core; \
    else \
      echo "Using local deriva-mcp-core directory from build context"; \
    fi

WORKDIR /deriva-mcp-core

ENV UV_PROJECT_ENVIRONMENT=/opt/venv
# Disable uv's download cache inside the build overlay -- Docker layer caching
# already handles reproducibility, so the uv cache only wastes disk space.
ENV UV_NO_CACHE=1
# uv.lock pins all transitive deps for reproducible builds.
# --no-editable installs the package into site-packages rather than using
# a .pth editable link back to the source tree (which won't exist at runtime).
RUN uv sync --frozen --no-dev --no-editable --extra rag

# Local plugin testing: copy facebase-deriva-mcp-plugin source into
#   deriva-docker/deriva/mcp/src/facebase-deriva-mcp-plugin/
# to activate. When pyproject.toml is absent only the .placeholder is present
# and this step is a no-op. --no-deps avoids resolving deriva-mcp-core from PyPI.
#COPY src/facebase-deriva-mcp-plugin ./facebase-deriva-mcp-plugin
#RUN if [ -f "./facebase-deriva-mcp-plugin/pyproject.toml" ]; then \
#      echo "Installing facebase-deriva-mcp-plugin from local source..."; \
#      uv pip install --python /opt/venv --no-deps ./facebase-deriva-mcp-plugin; \
#    fi

# Install any extra plugin packages declared at build time.
# Each package must declare the deriva_mcp.plugins entry point to be loaded.
# --no-sources: plugin pyproject.toml files may contain [tool.uv.sources] path
# overrides for local development (e.g. deriva-mcp-core = { path = "../..." }).
# uv pip install reads those overrides and fails when the relative path does not
# exist in the build context. --no-sources ignores them and resolves dependencies
# from PyPI instead.
RUN if [ -n "$EXTRA_PACKAGES" ]; then \
      echo "Installing extra packages: $EXTRA_PACKAGES"; \
      uv pip install --python /opt/venv --no-sources $EXTRA_PACKAGES; \
    fi


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

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["deriva-mcp-core", "--transport", "http", "--host", "0.0.0.0", "--port", "8000"]

LABEL org.opencontainers.image.title="deriva-mcp-core"
LABEL org.opencontainers.image.description="Reference implementation MCP server for the DERIVA platform"
LABEL org.opencontainers.image.licenses="Apache-2.0"