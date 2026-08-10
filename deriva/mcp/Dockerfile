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

# Install any extra plugin packages declared at build time.
# Each package must declare the deriva_mcp.plugins entry point to be loaded.
# --no-sources: plugin pyproject.toml files may contain [tool.uv.sources] path
# overrides for local development (e.g. deriva-mcp-core = { path = "../..." }).
# uv pip install reads those overrides and fails when the relative path does not
# exist in the build context. --no-sources ignores them and resolves dependencies
# from PyPI instead.
# LIMITATION: --no-sources is all-or-nothing. If a plugin depends on a package
# that is only available via git (not on PyPI at the required version), that
# dependency must also be listed explicitly in EXTRA_PACKAGES as a git URL, e.g.:
#   EXTRA_PACKAGES="dep@git+https://github.com/org/dep.git@main plugin@git+..."
# uv resolves all EXTRA_PACKAGES together so git-URL entries satisfy constraints.
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
ENV PYTHONPATH=/deriva-mcp-core/src
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Workflow-provenance environment variables.
#
# deriva-ml's Workflow Pydantic validator (`setup_url_checksum` in
# deriva-ml/execution/workflow.py) tries three strategies in order to
# fill in the Workflow row's url/checksum/version: (1) Docker mode --
# gated on DERIVA_MCP_IN_DOCKER=true, reads image-metadata env vars;
# (2) explicit DERIVA_ML_WORKFLOW_URL override; (3) git-binary
# introspection as fallback. The runtime stage of this image does not
# install `git`, so strategy 3 dies with "[Errno 2] No such file or
# directory: 'git'" -- which is exactly what the 2026-05-21 deriva-ml
# multi-persona e2e Curator persona observed (finding C02). The fix
# is to bake the strategy-1 envvars into the image so every
# Workflow(...) construction inside the container uses Docker
# provenance and never reaches the git fallback.
#
# Canonical reference for the variable contract:
# deriva-ml/docs/user-guide/reproducibility.md ("Bake these variables
# into the image so they are present when the container runs.") The
# upstream deriva-mcp/Dockerfile is the working precedent (its lines
# 100-113 set the same envvars from build args).
ARG VERSION
ARG GIT_COMMIT
ENV DERIVA_MCP_IN_DOCKER="true"
ENV DERIVA_MCP_IMAGE_NAME="ghcr.io/informatics-isi-edu/deriva-mcp-core"
ENV DERIVA_MCP_VERSION=${VERSION}
ENV DERIVA_MCP_GIT_COMMIT=${GIT_COMMIT}
ENV DERIVA_MCP_WORKFLOW_NAME="Deriva MCP Core Server"
ENV DERIVA_MCP_WORKFLOW_TYPE="Deriva MCP"

COPY config/rsyslog.conf /etc/rsyslog.conf
COPY config/ /etc/deriva-mcp/
COPY config/ /etc/deriva-mcp-defaults/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["deriva-mcp-core", "--transport", "http", "--host", "0.0.0.0", "--port", "8000"]

LABEL org.opencontainers.image.title="deriva-mcp-core"
LABEL org.opencontainers.image.description="Reference implementation MCP server for the DERIVA platform"
LABEL org.opencontainers.image.licenses="Apache-2.0"