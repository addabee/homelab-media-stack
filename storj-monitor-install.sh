#!/usr/bin/env bash
# Install the Storj node health monitor for the CURRENT user. No root required --
# it only reads the node's localhost dashboard API and writes to the user's own
# cron, config and state.
#
#   bash storj-monitor-install.sh
#
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin"; CONF="$HOME/.config/storj-monitor.conf"
mkdir -p "$BIN" "$HOME/.config" "$HOME/.local/state"
install -m 0755 "$SRC/storj-monitor.py" "$BIN/storj-monitor.py"

if [ ! -f "$CONF" ]; then
  install -m 0600 "$SRC/storj-monitor.conf.example" "$CONF"
  # ntfy topics are unguessable-by-obscurity: generate a long random one.
  TOPIC="storj-$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
  sed -i "s|^NTFY_TOPIC=.*|NTFY_TOPIC=$TOPIC|" "$CONF"
  echo "Generated ntfy topic: $TOPIC"
  echo "Subscribe to it in the ntfy app. Treat it as a password."
else
  echo "Keeping existing $CONF"
fi

TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v "storj-monitor" > "$TMP" || true
cat >> "$TMP" <<CRON
# Storj node health -- alerts on state change only (see $CONF)
*/15 * * * * $(command -v python3) $BIN/storj-monitor.py >> $HOME/.local/state/storj-monitor.log 2>&1
CRON
crontab "$TMP"; rm -f "$TMP"

echo
echo "Installed. Running once now:"
"$BIN/storj-monitor.py" || true
