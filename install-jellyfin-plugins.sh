#!/usr/bin/env bash
# Install the standard Jellyfin plugin set into the NATIVE server, then restart.
#
#   Playback Reporting   - watch history / stats                 (official repo)
#   TMDb Box Sets        - auto movie collections from TMDb       (official repo)
#   File Transformation  - dependency of Intro Skipper's skip UI  (3rd-party)
#   Intro Skipper        - detect & skip intros/credits           (3rd-party)
#
# Official plugin zips ship a meta.json. The two third-party zips ship only the
# DLL (they're meant for catalog install), so we write a matching meta.json --
# the same file Jellyfin would generate itself.
#
#   Run:  sudo bash /mnt/calculon/media-stack/install-jellyfin-plugins.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run me with sudo."; exit 1; }

PDIR=/var/lib/jellyfin/plugins
JF_OWNER="$(stat -c '%U:%G' /var/lib/jellyfin)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

install_zip_with_meta() {   # $1 name  $2 folder  $3 url
  local name="$1" folder="$2" url="$3" dest="$PDIR/$2"
  echo "== $name =="
  curl -fSL --retry 3 "$url" -o "$TMP/p.zip"
  rm -rf "$dest"; mkdir -p "$dest"
  unzip -oq "$TMP/p.zip" -d "$dest"
  # flatten a single wrapper dir if present
  if [ ! -e "$dest/meta.json" ]; then
    local sub; sub="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    [ -n "$sub" ] && { mv "$sub"/* "$dest"/ 2>/dev/null || true; rmdir "$sub" 2>/dev/null || true; }
  fi
  local v a
  v="$(jq -r '.version // "?"' "$dest/meta.json" 2>/dev/null || echo '?')"
  a="$(jq -r '.targetAbi // "?"' "$dest/meta.json" 2>/dev/null || echo '?')"
  echo "   v$v (targetAbi $a) -> $dest"
}

write_meta() {   # $1 folder  $2 guid  $3 name  $4 version  $5 targetAbi  $6 desc
  cat > "$PDIR/$1/meta.json" <<EOF
{
  "guid": "$2",
  "name": "$3",
  "description": "$6",
  "overview": "$6",
  "owner": "jellyfin-community",
  "category": "General",
  "version": "$4",
  "targetAbi": "$5",
  "framework": "net9.0",
  "changelog": "",
  "timestamp": "$NOW",
  "status": "Active",
  "autoUpdate": true,
  "imagePath": ""
}
EOF
}

# --- official (self-describing) ---
install_zip_with_meta "Playback Reporting" "PlaybackReporting" \
  "https://repo.jellyfin.org/files/plugin/playback-reporting/playback-reporting_17.0.0.0.zip"
install_zip_with_meta "TMDb Box Sets" "TMDbBoxSets" \
  "https://repo.jellyfin.org/files/plugin/tmdb-box-sets/tmdb-box-sets_13.0.0.0.zip"

# --- third-party (DLL-only zips, we add meta.json) ---
install_zip_with_meta "File Transformation" "FileTransformation" \
  "https://github.com/IAmParadox27/jellyfin-plugin-file-transformation/releases/download/2.5.11.0/Release-10.11.11.zip"
write_meta "FileTransformation" "5e87cc92-571a-4d8d-8d98-d2d4147f9f90" \
  "File Transformation" "2.5.11.0" "10.11.0.0" \
  "Allows plugins to register transformations against files served by Jellyfin. Required by Intro Skipper's skip button."

# NOTE: use the "10.11/*" release line (built for STABLE Jellyfin 10.11.x).
# The "12.0/*" line targets 10.11 nightly and fails to load on 10.11.11.
install_zip_with_meta "Intro Skipper" "IntroSkipper" \
  "https://github.com/intro-skipper/intro-skipper/releases/download/10.11/v1.10.11.23/intro-skipper-v1.10.11.23.zip"
write_meta "IntroSkipper" "c83d86bb-a1e0-4c35-a113-e2101cf4ee6b" \
  "Intro Skipper" "1.10.11.23" "10.11.0.0" \
  "Analyzes the audio of episodes to detect and skip intros and end credits."

chown -R "$JF_OWNER" "$PDIR"
echo
echo "== restarting jellyfin =="
systemctl restart jellyfin
sleep 4
systemctl is-active jellyfin && echo "jellyfin is up"

echo
cat <<'EOF'
Next:
  - Dashboard -> Plugins : all five entries should read "Active"
    (Playback Reporting, TMDb Box Sets, File Transformation, Intro Skipper).
    If Intro Skipper shows "Malfunctioned" the first time, restart Jellyfin once
    more -- it needs File Transformation to have loaded first.
  - For auto-updates later, add these repositories in
    Dashboard -> Plugins -> Repositories:
      Intro Skipper       https://manifest.intro-skipper.org/manifest.json
      File Transformation  https://raw.githubusercontent.com/IAmParadox27/jellyfin-plugin-repo/main/manifest.json
  - Intro Skipper: run "Detect and Analyze Media" once from
    Dashboard -> Scheduled Tasks after libraries are added.
EOF
