#!/usr/bin/env bash
# Install the full DERIVA stack (postgres, rabbitmq, apache, keycloak, credenza,
# traefik, mcp-core, mcp-ui, jupyter, monitoring).
# Runs install-system.sh first, then installs the full-stack systemd unit
# and the update-stack utility.
#
# Note: docker-compose-full-aws.yml is still a sketch -- see that file for
# what remains to be validated before this stack is production-ready.
#
# Usage (as root from the repo root):
#   utils/sysinstall/bin/install-full-stack.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Generic system provisioning
# ---------------------------------------------------------------------------
echo "[install-full-stack] Running system installer..."
"$ROOT_DIR/bin/install-system.sh"

# ---------------------------------------------------------------------------
# deriva-full systemd unit
# ---------------------------------------------------------------------------
echo ""
echo "[install-full-stack] Installing deriva-full.service..."
install -D -m 0644 \
  "$ROOT_DIR/systemd/deriva-full.service" \
  /etc/systemd/system/deriva-full.service

systemctl daemon-reload
systemctl enable deriva-full
echo "[install-full-stack] deriva-full.service enabled (not started)."

# ---------------------------------------------------------------------------
# update-stack utility
# ---------------------------------------------------------------------------
install -D -m 0755 \
  "$ROOT_DIR/bin/update-stack.sh" \
  /usr/local/sbin/update-stack.sh
echo "[install-full-stack] Installed update-stack.sh -> /usr/local/sbin/update-stack.sh"

echo ""
echo "[install-full-stack] Done. To start the stack:"
echo "  systemctl start deriva-full"