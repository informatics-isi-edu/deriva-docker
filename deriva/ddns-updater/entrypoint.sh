#!/bin/bash

SECRET_FILE="/run/secrets/ydns.env"

cleanup() {
  echo "Caught termination signal. Cleaning up..."
  exit 0
}

# Trap INT and TERM
trap cleanup SIGINT SIGTERM

if [ ! -f "$SECRET_FILE" ]; then
  echo "❌   Required DDNS secret file '$SECRET_FILE' not found or is not a file."
  exit 1
fi

echo "✅   Found secret file."
echo "Attempting to pre-register hostname(s)..."

. "$SECRET_FILE" && /usr/local/bin/ydns_update.sh -V

echo "Starting DDNS updater..."
crond -f -L /dev/stdout &

# Wait for background crond and handle signals
wait $!

