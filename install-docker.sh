#!/usr/bin/env bash
# Install Docker CE + compose plugin from Docker's official apt repo,
# and add the current desktop user to the 'docker' group.
#   Run:  sudo bash /mnt/calculon/media-stack/install-docker.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run me with sudo."; exit 1; }
TARGET_USER="${SUDO_USER:-$(id -un)}"

echo "== 1. prerequisites =="
apt-get update -qq
apt-get install -y ca-certificates curl

echo "== 2. Docker apt repo (Ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME")) =="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
CODENAME="$VERSION_CODENAME"
# Docker publishes 'resolute'; fall back to 'noble' if that ever 404s.
if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1; then
  echo "   (no Docker repo for '${CODENAME}', falling back to 'noble')"
  CODENAME="noble"
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "== 3. install =="
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "== 4. enable + start =="
systemctl enable --now docker

echo "== 5. add ${TARGET_USER} to docker group =="
usermod -aG docker "$TARGET_USER"

echo
docker --version
docker compose version
echo
echo "DONE. Log out/in (or run 'newgrp docker') so '${TARGET_USER}' can use docker without sudo."
