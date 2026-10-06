#!/usr/bin/env bash
# Pull newer images for this compose stack and recreate whatever changed.
# Runs from cron on a schedule (see --install); safe to run by hand any time.
#
#   ./update-stack.sh             pull + recreate changed containers
#   ./update-stack.sh --dry-run   show what would happen, change nothing
#   ./update-stack.sh --install   add the weekly cron entry (Sun 04:30)
#
# Only touches services in docker-compose.yml. Containers started with plain
# 'docker run' are left alone on purpose -- storagenode updates its own binary
# from inside the container.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SCHEDULE="30 4 * * 0"         # Sunday 04:30 -- quietest time for a brief restart
LOG="$HOME/.local/state/update-stack.log"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$(dirname "$LOG")"
  TMP="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "update-stack.sh" > "$TMP" || true
  cat >> "$TMP" <<CRON
# Weekly container image updates for the media stack (see $PWD/update-stack.sh)
$SCHEDULE $PWD/update-stack.sh >> $LOG 2>&1
CRON
  crontab "$TMP"; rm -f "$TMP"
  echo "Installed: '$SCHEDULE' -> $LOG"
  exit 0
fi

DRY=(); [ "${1:-}" = "--dry-run" ] && DRY=(--dry-run)

# One run at a time, even if a manual run overlaps the cron one.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/update-stack.lock"
flock -n 9 || { echo "another update is already running"; exit 1; }

echo "== $(date -Is) update-stack ${DRY[*]}"
docker compose "${DRY[@]}" pull --quiet
docker compose "${DRY[@]}" up -d

[ ${#DRY[@]} -gt 0 ] && exit 0

# qbittorrent and flaresolverr live inside gluetun's network namespace. If
# gluetun was replaced but they weren't, they're attached to a container that
# no longer exists and have no network at all -- recreate them onto the new one.
gluetun_id=$(docker inspect -f '{{.Id}}' gluetun)
for svc in qbittorrent flaresolverr; do
  mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$svc")
  if [ "$mode" != "container:$gluetun_id" ]; then
    echo "   $svc is attached to a stale gluetun -- recreating"
    docker compose up -d --force-recreate --no-deps "$svc"
  fi
done

# Drop the superseded images so the root disk doesn't fill up week by week.
docker image prune -f | tail -1
echo "== done"
