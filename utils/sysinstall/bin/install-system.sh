#!/usr/bin/env bash
# Install system packages, EBS mount service, and Docker data-root configuration.
# This script is stack-agnostic -- run it once per host before any stack installer.
#
# Usage (as root):
#   install-system.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
[[ -f /etc/deriva-docker/deriva-stack.env ]] && . /etc/deriva-docker/deriva-stack.env
EBS_MOUNTS="${EBS_MOUNTS:-/dev/nvme1n1:/data:defaults,nofail}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/data/docker}"

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
echo "[install-system] Installing system packages..."
"$ROOT_DIR/bin/install-packages.sh"

# ---------------------------------------------------------------------------
# EBS mount script + service
# The script must land on the rootfs before mounts are active so systemd
# can find it at boot regardless of whether /data is mounted yet.
# ---------------------------------------------------------------------------
echo ""
echo "[install-system] Installing mount-ebs-volumes..."
install -D -m 0755 \
  "$ROOT_DIR/bin/mount-ebs-volumes.sh" \
  /usr/local/sbin/mount-ebs-volumes.sh

install -D -m 0644 \
  "$ROOT_DIR/systemd/mount-ebs-volumes.service" \
  /etc/systemd/system/mount-ebs-volumes.service

systemctl daemon-reload
systemctl reset-failed mount-ebs-volumes.service >/dev/null 2>&1 || true
systemctl enable --now mount-ebs-volumes.service

# Verify all configured mounts are active
exit_code=0
for entry in $EBS_MOUNTS; do
  rest="${entry#*:}"; mnt="${rest%%:*}"
  if ! mountpoint -q "$mnt"; then
    echo "[install-system] ERROR: $mnt is not mounted."
    systemctl status mount-ebs-volumes.service || true
    journalctl -u mount-ebs-volumes.service -n 200 --no-pager || true
    exit_code=1
  fi
done
[[ "$exit_code" -ne 0 ]] && exit "$exit_code"
echo "[install-system] OK: all configured mounts are active."

# ---------------------------------------------------------------------------
# Docker data-root
# ---------------------------------------------------------------------------
echo ""
echo "[install-system] Configuring Docker data-root at ${DOCKER_DATA_ROOT}..."
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
mkdir -p "$DOCKER_DATA_ROOT"
if [[ -f "$DOCKER_DAEMON_JSON" ]] && grep -q '"data-root"' "$DOCKER_DAEMON_JSON"; then
  echo "[install-system] Docker data-root already set; skipping."
elif [[ -f "$DOCKER_DAEMON_JSON" ]]; then
  echo "[install-system] WARNING: ${DOCKER_DAEMON_JSON} exists without data-root. Add manually:"
  echo "  \"data-root\": \"${DOCKER_DATA_ROOT}\""
else
  cat > "$DOCKER_DAEMON_JSON" <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "builder": {
    "gc": {
      "enabled": true,
      "defaultKeepStorage": "2GB"
    }
  }
}
EOF
  echo "[install-system] Written ${DOCKER_DAEMON_JSON}"
  if systemctl is-active --quiet docker; then
    echo "[install-system] Restarting Docker to apply data-root change..."
    systemctl restart docker
  fi
fi

echo ""
echo "[install-system] Done."