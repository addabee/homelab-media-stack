#!/usr/bin/env bash
# Add the Movies / Shows / Music libraries to the native Jellyfin server.
#   Usage:  bash add-jellyfin-libraries.sh <API_KEY>
# Get an API key from Jellyfin -> Dashboard -> Administration -> API Keys.
set -euo pipefail
KEY="${1:?pass the Jellyfin API key as the first argument}"
JF="http://localhost:8096"

add() {  # $1 name  $2 collectionType  $3 host-path
  local name="$1" ctype="$2" path="$3"
  echo "== $name ($ctype) -> $path"
  curl -fsS -G "$JF/Library/VirtualFolders" \
    --data-urlencode "name=$name" \
    --data-urlencode "collectionType=$ctype" \
    --data-urlencode "paths=$path" \
    --data-urlencode "refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$KEY\"" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{
          "LibraryOptions": {
            "EnableRealtimeMonitor": true,
            "EnableChapterImageExtraction": false,
            "SaveLocalMetadata": true,
            "EnableInternetProviders": true,
            "AutomaticRefreshIntervalDays": 0
          }
        }' && echo "  ok" || echo "  FAILED"
}

add "Movies" "movies"  "/mnt/calculon/media/movies"
add "Shows"  "tvshows" "/mnt/calculon/media/tv"
add "Music"  "music"   "/mnt/calculon/media/music"

echo
echo "Current libraries:"
curl -fsS "$JF/Library/VirtualFolders" -H "Authorization: MediaBrowser Token=\"$KEY\"" \
  | python3 -c 'import json,sys; [print(f"  {v[\"Name\"]:8} {v.get(\"CollectionType\",\"-\"):8} {v[\"Locations\"]}") for v in json.load(sys.stdin)]'
