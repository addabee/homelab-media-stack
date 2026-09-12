#!/usr/bin/env bash
# Point qBittorrent at the correct in-container paths, turn on Automatic Torrent
# Management (so a torrent's *category* decides where it lands), and set the
# listen port to the one PIA forwarded. Categories themselves are defined in
#   appdata/qbittorrent/qBittorrent/categories.json
#
# qBittorrent rewrites its config on shutdown, so we stop the container, patch
# the file, then start it again.
#
#   Run:  sudo bash /mnt/calculon/media-stack/configure-qbittorrent.sh
set -euo pipefail
cd /mnt/calculon/media-stack
CONF=appdata/qbittorrent/qBittorrent/qBittorrent.conf
CATS=appdata/qbittorrent/qBittorrent/categories.json

command -v docker >/dev/null || { echo "docker not found"; exit 1; }

# Web UI credentials are NOT stored in this repo -- it is public. If .env sets
# QBITTORRENT_PASSWORD_PBKDF2 we write it; otherwise the existing password in
# qBittorrent.conf is left exactly as it is. See .env.example for how to
# generate the hash.
envget(){ sed -nE "s/^$1=(.*)$/\1/p" ./.env 2>/dev/null | tail -1; }
QB_PBKDF2="$(envget QBITTORRENT_PASSWORD_PBKDF2)"
QB_USER="$(envget QBITTORRENT_USERNAME)"; QB_USER="${QB_USER:-admin}"
if [ -n "$QB_PBKDF2" ]; then
  echo "== Web UI password: setting from .env (user: $QB_USER) =="
else
  echo "== Web UI password: leaving as-is (QBITTORRENT_PASSWORD_PBKDF2 unset) =="
fi

echo "== reading forwarded port from gluetun =="
PORT="$(docker compose exec -T gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null | tr -dc 0-9 || true)"
[ -n "${PORT:-}" ] || PORT=21524
echo "   using listen port: $PORT"

echo "== stopping qbittorrent =="
docker compose stop qbittorrent

cp -a "$CONF" "$CONF.bak.$(date +%s)"

echo "== patching $CONF =="
PORT="$PORT" QB_PBKDF2="$QB_PBKDF2" QB_USER="$QB_USER" python3 - "$CONF" <<'PY'
import os, sys
port = os.environ["PORT"]
qb_pbkdf2 = os.environ.get("QB_PBKDF2", "")
qb_user = os.environ.get("QB_USER", "admin")
path = sys.argv[1]
want = {
  "BitTorrent": {
    r"Session\DefaultSavePath": "/data/downloads/complete",
    r"Session\TempPath": "/data/downloads/incomplete",
    r"Session\TempPathEnabled": "true",
    r"Session\Port": port,
    r"Session\UseCategoryPathsInManualMode": "true",
    r"Session\DisableAutoTMMByDefault": "false",
    r"Session\DisableAutoTMMTriggers\CategoryChanged": "false",
    r"Session\DisableAutoTMMTriggers\CategorySavePathChanged": "false",
    r"Session\DisableAutoTMMTriggers\DefaultSavePathChanged": "false",
  },
  "Preferences": {
    r"Downloads\SavePath": "/data/downloads/complete/",
    r"Downloads\TempPath": "/data/downloads/incomplete/",
    r"Downloads\TempPathEnabled": "true",
    r"Connection\PortRangeMin": port,
    r"Connection\UPnP": "false",
    # let Sonarr/Radarr/Prowlarr (on the 172.28.0.0/24 compose net) reach the
    # Web UI API without a password; humans on the LAN still need to log in
    r"WebUI\AuthSubnetWhitelistEnabled": "true",
    r"WebUI\AuthSubnetWhitelist": "172.28.0.0/24",
    r"WebUI\HostHeaderValidation": "false",
  },
}

# Only touch the login when .env supplies a hash. Never hardcode one here:
# this repo is public, so a committed hash is a published credential and
# would silently overwrite the password set through the Web UI.
if qb_pbkdf2:
    want["Preferences"][r"WebUI\Username"] = qb_user
    want["Preferences"][r"WebUI\Password_PBKDF2"] = f'"{qb_pbkdf2}"'

lines = open(path).read().splitlines()
out, sec, seen = [], None, {k: set() for k in want}

def flush(sec):
    if sec in want:
        for k, v in want[sec].items():
            if k not in seen[sec]:
                out.append(f"{k}={v}")

for ln in lines:
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        flush(sec)
        sec = s[1:-1]
        out.append(ln)
        continue
    if sec in want and "=" in ln and not s.startswith("#"):
        key = ln.split("=", 1)[0].strip()
        if key in want[sec]:
            out.append(f"{key}={want[sec][key]}")
            seen[sec].add(key)
            continue
    out.append(ln)
flush(sec)

# ensure both target sections exist
text = "\n".join(out)
for s in want:
    if f"[{s}]" not in text:
        text += f"\n[{s}]\n" + "\n".join(f"{k}={v}" for k, v in want[s].items()
                                          if k not in seen[s])
open(path, "w").write(text.rstrip() + "\n")
print("   done")
PY

chown 1000:1000 "$CONF" "$CATS"

echo "== starting qbittorrent =="
docker compose start qbittorrent
sleep 3
docker compose ps qbittorrent

cat <<EOF

qBittorrent is now configured:
  incomplete downloads -> /data/downloads/incomplete   (/mnt/calculon/downloads/incomplete)
  completed, by category:
    radarr   -> /data/downloads/complete/movies
    sonarr   -> /data/downloads/complete/tv
    music    -> /data/downloads/complete/music
    books    -> /data/downloads/complete/books
    manual   -> /data/downloads/complete/manual
  Automatic Torrent Management: ON by default (category = location)
  listen port: $PORT
  Web UI login: ${QB_PBKDF2:+set from .env (user: $QB_USER)}${QB_PBKDF2:-unchanged}

Web UI: http://192.168.1.64:8080  (Tools -> Options -> BitTorrent: confirm
"Automatic Torrent Management" shows the category paths above).
EOF
