#!/bin/sh

trap "echo 'Shutting down Keycloak healthcheck loop'; exit" SIGTERM SIGINT

echo "🔁   Starting Keycloak health check loop..."
url="http://keycloak:9000/auth/health/ready"
was_ready=1

while true; do
  if curl -sf "$url" > /dev/null; then
    if [ "$was_ready" -eq 0 ]; then
      echo "$(date)  ✅   Keycloak is ready"
      was_ready=1
    fi
  else
    if [ "$was_ready" -eq 1 ]; then
      echo "$(date)  ❌   Keycloak is NOT ready"
      was_ready=0
    fi
  fi
  sleep 30
done
