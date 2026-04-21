#!/usr/bin/env bash
# Install the DERIVA lean MCP stack (mcp-core + mcp-ui + credenza + traefik).
# Runs install-system.sh first, then installs the MCP-specific systemd unit
# and the update-stack utility.
#
# Usage (as root from the repo root):
#   utils/sysinstall/bin/install-mcp-stack.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Generic system provisioning
# ---------------------------------------------------------------------------
echo "[install-mcp-stack] Running system installer..."
"$ROOT_DIR/bin/install-system.sh"

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
WORK_DIR="/data/deriva-docker/deriva"

if [[ -f "$STACK_ENV" ]]; then
  echo ""
  echo "[install-mcp-stack] Pre-building images (this may take a while)..."
  cd "$WORK_DIR"
  docker compose --env-file "$STACK_ENV" build --pull
  echo "[install-mcp-stack] Image build complete."
else
  echo ""
  echo "[install-mcp-stack] WARNING: $STACK_ENV not found; skipping image pre-build."
  echo "  Run generate-env.sh --install first, then: docker compose build --pull"
fi

# ---------------------------------------------------------------------------
# Seed operator config files into config-mnt directories.
# These paths are bind-mounted by docker-compose-mcp-aws.yml so operator
# edits persist across image rebuilds and git pulls.
# cp -n skips files that already exist to preserve operator customisations.
# ---------------------------------------------------------------------------
echo ""
echo "[install-mcp-stack] Seeding operator config files..."
for entry in \
  "mcp/config/deriva-mcp.env:mcp/config-mnt/deriva-mcp.env" \
  "mcp-ui/config/deriva-mcp-ui.env:mcp-ui/config-mnt/deriva-mcp-ui.env"
do
  src="$WORK_DIR/${entry%%:*}"
  dest="$WORK_DIR/${entry##*:}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    echo "  Skipping $dest (already exists)"
  else
    cp "$src" "$dest"
    echo "  Seeded $dest"
  fi
done

echo ""
echo "[install-mcp-stack] Done. To start the stack:"
echo "  systemctl start deriva-mcp"