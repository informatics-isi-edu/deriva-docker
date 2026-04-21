#!/usr/bin/env bash
# Rebuild and restart a DERIVA stack managed by a named systemd service.
#
# Usage (as root):
#   update-stack.sh <service> [--no-cache]
#
#   <service>     systemd service name (e.g. deriva-mcp, deriva-full)
#   --no-cache    Pass --no-cache to docker compose build (full layer rebuild)

set -euo pipefail

STACK_ENV="/etc/deriva-docker/deriva-stack.env"
WORK_DIR="/opt/deriva-docker/deriva"
NO_CACHE_FLAG=""
SERVICE=""

for arg in "$@"; do
  case $arg in
    --no-cache) NO_CACHE_FLAG="--no-cache" ;;
    --help|-h)  sed -n '2,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown option: $arg"; exit 1 ;;
    *)  SERVICE="$arg" ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "Usage: update-stack.sh <service> [--no-cache]"
  echo "  e.g. update-stack.sh deriva-mcp"
  exit 1
fi

if [[ ! -f "$STACK_ENV" ]]; then
  echo "[update-stack] ERROR: $STACK_ENV not found. Run generate-env.sh --install first."
  exit 1
fi

cd "$WORK_DIR"

echo "[update-stack] Stopping ${SERVICE}..."
systemctl stop "$SERVICE"

echo "[update-stack] Building images..."
docker compose --env-file "$STACK_ENV" build --pull $NO_CACHE_FLAG

echo "[update-stack] Starting ${SERVICE}..."
systemctl start "$SERVICE"

echo "[update-stack] Done."
docker compose --env-file "$STACK_ENV" ps