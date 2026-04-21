#!/usr/bin/env bash
set -euo pipefail

# Install system packages required for the DERIVA MCP stack on Ubuntu 24.04.
# Safe to re-run: apt-get install is idempotent and the Docker repo setup is
# guarded by checks before each step.

DOCKER_APT_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_APT_SOURCE="/etc/apt/sources.list.d/docker.list"

echo "[install-packages] Updating apt package index..."
apt-get update -qq

echo "[install-packages] Installing prerequisite packages..."
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  jq \
  rsync \
  unzip \
  htop \
  iotop

echo "[install-packages] Configuring Docker apt repository..."
install -m 0755 -d /etc/apt/keyrings

if [[ ! -f "$DOCKER_APT_KEYRING" ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_APT_KEYRING"
  chmod a+r "$DOCKER_APT_KEYRING"
  echo "[install-packages] Docker GPG key installed."
else
  echo "[install-packages] Docker GPG key already present; skipping."
fi

if [[ ! -f "$DOCKER_APT_SOURCE" ]]; then
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_APT_KEYRING}]" \
    "https://download.docker.com/linux/ubuntu" \
    "$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > "$DOCKER_APT_SOURCE"
  apt-get update -qq
  echo "[install-packages] Docker apt source configured."
else
  echo "[install-packages] Docker apt source already configured; skipping."
fi

echo "[install-packages] Installing Docker..."
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

echo "[install-packages] Installing AWS CLI v2..."
if command -v aws &>/dev/null; then
  echo "[install-packages] AWS CLI already installed ($(aws --version 2>&1)); skipping."
else
  AWSCLI_TMP=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${AWSCLI_TMP}/awscliv2.zip"
  unzip -q "${AWSCLI_TMP}/awscliv2.zip" -d "${AWSCLI_TMP}"
  "${AWSCLI_TMP}/aws/install"
  rm -rf "${AWSCLI_TMP}"
  echo "[install-packages] AWS CLI v2 installed ($(aws --version 2>&1))."
fi

echo ""
echo "[install-packages] Done."
echo "  Docker:      $(docker --version)"
echo "  Compose:     $(docker compose version)"
echo "  AWS CLI:     $(aws --version 2>&1)"