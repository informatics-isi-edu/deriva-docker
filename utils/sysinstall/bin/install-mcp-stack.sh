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

echo ""
echo "[install-mcp-stack] Done. To start the stack:"
echo "  systemctl start deriva-mcp"