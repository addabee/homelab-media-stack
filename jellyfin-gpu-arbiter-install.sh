#!/usr/bin/env bash
# One-time installer for the Jellyfin GPU/CPU transcoding arbiter.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep a timestamped backup of whatever is live right now.
[ -f /etc/jellyfin/encoding.xml ] && \
  cp -a /etc/jellyfin/encoding.xml "/etc/jellyfin/encoding.xml.bak.$(date +%Y%m%d-%H%M%S)"

install -o jellyfin -g jellyfin -m 644 "$SRC/jellyfin-encoding.optimized.xml" /etc/jellyfin/encoding.gpu.xml
install -o jellyfin -g jellyfin -m 644 "$SRC/jellyfin-encoding.cpu.xml"       /etc/jellyfin/encoding.cpu.xml
install -m 0755 "$SRC/jellyfin-gpu-arbiter.sh" /usr/local/sbin/jellyfin-gpu-arbiter.sh

# Reuse the ntfy topic already configured for the Storj monitor, if present.
if [ ! -f /etc/jellyfin-gpu-arbiter.conf ]; then
  OWNER="${SUDO_USER:-$(id -un)}"
  OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
  TOPIC="$(grep -h '^NTFY_TOPIC=' "${OWNER_HOME}/.config/storj-monitor.conf" 2>/dev/null | cut -d= -f2 || true)"
  cat > /etc/jellyfin-gpu-arbiter.conf <<CONF
# Alerts share the Storj monitor's ntfy topic. Blank NTFY_TOPIC to disable.
NTFY_SERVER=https://ntfy.sh
NTFY_TOPIC=${TOPIC}
# Consecutive agreeing polls required before switching (each poll is 60s).
CONFIRMATIONS=2
CONF
  chmod 600 /etc/jellyfin-gpu-arbiter.conf
fi

cat > /etc/systemd/system/jellyfin-gpu-arbiter.service <<'UNIT'
[Unit]
Description=Switch Jellyfin between NVENC and CPU transcoding based on GPU tenancy
After=docker.service jellyfin.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/jellyfin-gpu-arbiter.sh
UNIT

cat > /etc/systemd/system/jellyfin-gpu-arbiter.timer <<'UNIT'
[Unit]
Description=Poll GPU tenancy for the Jellyfin transcoding arbiter

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now jellyfin-gpu-arbiter.timer
echo
echo "Installed. Profiles:"
ls -l /etc/jellyfin/encoding.gpu.xml /etc/jellyfin/encoding.cpu.xml
echo
echo "Run once by hand to see what it decides:"
echo "  sudo /usr/local/sbin/jellyfin-gpu-arbiter.sh"
