#!/usr/bin/env bash
# Install the DERIVA lean MCP stack (mcp-core + mcp-ui + credenza + traefik).
#
# Usage (as root, clone once, four steps):
#
#   git clone <repo-url> /root/deriva-docker
#   cd /root/deriva-docker
#
#   # Step 1: mount EBS and configure Docker data-root on /data
#   utils/sysinstall/bin/install-system.sh
#
#   # Step 2: generate the env file with --output-dir on /data so secrets
#   #         persist across root volume replacement, then install the symlink
#   utils/generate-env.sh --env prod --hostname <host> --email <email> \
#     --enable-mcp-aws --llm-api-key <key> \
#     --output-dir /data/deriva-docker/.env --install
#   #
#   # To reuse an existing env instead of generating a fresh one:
#   #   mkdir -p /data/deriva-docker/.env
#   #   cp /path/to/existing.env /data/deriva-docker/.env/<host>.env
#   #   cp -r /path/to/secrets   /data/deriva-docker/.env/secrets
#   #   mkdir -p /etc/deriva-docker
#   #   ln -sf /data/deriva-docker/.env/<host>.env \
#   #          /etc/deriva-docker/deriva-stack.env
#
#   # Step 3: provision the host and install the stack.
#   #   install-system.sh re-runs here (idempotent); the repo is then copied
#   #   to /data/deriva-docker and this script re-execs from there.
#   utils/sysinstall/bin/install-mcp-stack.sh
#
#   # Step 4: start the stack
#   systemctl start deriva-mcp
#
# After a root volume replacement: re-clone anywhere, re-run install-system.sh
# to remount EBS, then re-run this script from /data/deriva-docker (the repo
# and env on /data are already intact).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CANONICAL_DIR="/data/deriva-docker"

# ---------------------------------------------------------------------------
# Generic system provisioning (mounts EBS, configures Docker data-root)
# ---------------------------------------------------------------------------
echo "[install-mcp-stack] Running system installer..."
"$ROOT_DIR/bin/install-system.sh"

# ---------------------------------------------------------------------------
# Relocate repo to canonical EBS location if needed, then re-exec.
# install-system.sh above ensures /data is mounted before this check.
# ---------------------------------------------------------------------------
if [[ "$(realpath "$REPO_ROOT")" != "$CANONICAL_DIR" ]]; then
  if [[ -f "$CANONICAL_DIR/utils/sysinstall/bin/install-mcp-stack.sh" ]]; then
    echo "[install-mcp-stack] ERROR: a repo is already present at $CANONICAL_DIR."
    echo "  Re-run this script from $CANONICAL_DIR directly."
    exit 1
  fi
  echo ""
  echo "[install-mcp-stack] Copying repo to $CANONICAL_DIR..."
  mkdir -p "$CANONICAL_DIR"
  cp -a "$REPO_ROOT/." "$CANONICAL_DIR/"
  echo "[install-mcp-stack] Re-executing from $CANONICAL_DIR..."
  exec "$CANONICAL_DIR/utils/sysinstall/bin/install-mcp-stack.sh" "$@"
fi

# ---------------------------------------------------------------------------
# deriva-mcp systemd unit
# ---------------------------------------------------------------------------
echo ""
echo "[install-mcp-stack] Installing deriva-mcp.service..."
install -D -m 0644 \
  "$ROOT_DIR/systemd/deriva-mcp.service" \
  /etc/systemd/system/deriva-mcp.service

systemctl daemon-reload
systemctl enable deriva-mcp
echo "[install-mcp-stack] deriva-mcp.service enabled (not started)."

# ---------------------------------------------------------------------------
# update-stack utility
# ---------------------------------------------------------------------------
install -D -m 0755 \
  "$ROOT_DIR/bin/update-stack.sh" \
  /usr/local/sbin/update-stack.sh
echo "[install-mcp-stack] Installed update-stack.sh -> /usr/local/sbin/update-stack.sh"

# ---------------------------------------------------------------------------
# Pre-build images so the first 'systemctl start' is fast
# ---------------------------------------------------------------------------
STACK_ENV="/etc/deriva-docker/deriva-stack.env"

if [[ -f "$STACK_ENV" ]]; then
  echo ""
  echo "[install-mcp-stack] Pre-building images (this may take a while)..."
  cd "${CANONICAL_DIR}/deriva"
  docker compose --env-file "$STACK_ENV" build --pull
  echo "[install-mcp-stack] Image build complete."
else
  echo ""
  echo "[install-mcp-stack] WARNING: $STACK_ENV not found; skipping image pre-build."
  echo "  Run generate-env.sh --output-dir /data/deriva-docker/.env --install first, then:"
  echo "  cd ${CANONICAL_DIR}/deriva && docker compose --env-file $STACK_ENV build --pull"
fi

echo ""
echo "[install-mcp-stack] Done. To start the stack:"
echo "  systemctl start deriva-mcp"