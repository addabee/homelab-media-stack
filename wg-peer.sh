#!/usr/bin/env bash
# Manage WireGuard peers (devices) on the native wg0 server.
#
#   sudo ./wg-peer.sh add <name> [--full]   create a peer, show its QR + config
#   sudo ./wg-peer.sh show <name>           re-show an existing peer's QR + config
#   sudo ./wg-peer.sh list                  peers, tunnel IPs, mode
#   sudo ./wg-peer.sh status                who is connected (wg show, with names)
#   sudo ./wg-peer.sh remove <name>         revoke a device
#
# Default is a SPLIT tunnel: only 192.168.1.0/24 and the tunnel subnet go
# through the VPN, everything else uses the device's normal connection. That is
# what remote admin of the *arr apps needs and it costs nothing when idle.
# --full routes ALL of the device's traffic through home (0.0.0.0/0, ::/0) --
# use it for hostile Wi-Fi. A peer's mode is fixed at creation; to change it,
# remove and re-add.
#
# Client private keys are generated here and kept in /etc/wireguard/peers/
# (root-only) so a config can be re-shown; delete a peer to destroy its key.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run me with sudo."; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"

WG_IF=wg0
CONF=/etc/wireguard/$WG_IF.conf
PEERS=/etc/wireguard/peers
LAN=192.168.1.0/24
FULL_DNS=1.1.1.1              # only used by --full peers; split peers keep their own DNS

[ -f "$CONF" ] || { echo "$CONF missing -- run wireguard-install.sh first" >&2; exit 1; }
umask 077; mkdir -p "$PEERS"

# Server facts, read from the live config rather than duplicated here.
SERVER_PRIV=$(sed -nE 's/^PrivateKey *= *//p' "$CONF" | head -1)
SERVER_PUB=$(wg pubkey <<<"$SERVER_PRIV")
SERVER_ADDR=$(sed -nE 's/^Address *= *//p' "$CONF" | head -1)     # 10.13.13.1/24
WG_PORT=$(sed -nE 's/^ListenPort *= *//p' "$CONF" | head -1)
WG_SUBNET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$SERVER_ADDR")  # 10.13.13.0/24
PREFIX=${WG_SUBNET%.*}        # 10.13.13

# Endpoint = the DuckDNS name Caddy already uses. Don't source .env wholesale
# (unquoted values like PIA_REGION="CA Toronto" would be executed).
SUB=$(sed -nE 's/^DUCKDNS_SUBDOMAIN=(.*)$/\1/p' ./.env | tail -1)
[ -n "$SUB" ] || { echo "DUCKDNS_SUBDOMAIN not set in .env" >&2; exit 1; }
ENDPOINT="$SUB.duckdns.org:$WG_PORT"

usage(){ sed -nE '3,9p' "$0" | sed 's/^# //'; exit 1; }
valid_name(){ [[ "$1" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || { echo "name: 1-15 chars of [A-Za-z0-9_-] (it becomes the client's interface name)" >&2; exit 1; }; }
has_peer(){ grep -qx "# peer: $1" "$CONF"; }

# Apply the on-disk config to the running interface without dropping other peers.
sync(){ wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); }

next_ip(){
  local used n
  used=$(sed -nE "s#^AllowedIPs *= *$PREFIX\.([0-9]+)/32.*#\1#p" "$CONF")
  for n in $(seq 2 254); do
    grep -qx "$n" <<<"$used" || { echo "$PREFIX.$n"; return; }
  done
  echo "subnet full" >&2; exit 1
}

show_peer(){
  local f="$PEERS/$1.conf"
  [ -f "$f" ] || { echo "no such peer: $1" >&2; exit 1; }
  echo; echo "== $1 ==  ($(sed -nE 's/^# mode: //p' "$f") tunnel, endpoint $ENDPOINT)"
  echo "Scan with the WireGuard app (Add tunnel -> QR):"
  qrencode -t ansiutf8 < "$f"
  echo "...or import this file on a laptop:"
  echo "----- $f -----"; cat "$f"; echo "-----"
}

cmd=${1:-}; shift || true
case "$cmd" in
  add)
    name=${1:-}; [ -n "$name" ] || usage; valid_name "$name"
    mode=split; [ "${2:-}" = "--full" ] && mode=full
    has_peer "$name" && { echo "peer '$name' already exists (use show / remove)" >&2; exit 1; }

    ip=$(next_ip)
    priv=$(wg genkey); pub=$(wg pubkey <<<"$priv"); psk=$(wg genpsk)

    if [ "$mode" = full ]; then allowed="0.0.0.0/0, ::/0"; dns="DNS = $FULL_DNS"
    else allowed="$WG_SUBNET, $LAN"; dns="# DNS: not set -- device keeps its own resolver (split tunnel)"; fi

    cat > "$PEERS/$name.conf" <<CLIENT
# mode: $mode
[Interface]
PrivateKey = $priv
Address = $ip/32
$dns

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $psk
Endpoint = $ENDPOINT
AllowedIPs = $allowed
PersistentKeepalive = 25
CLIENT

    cat >> "$CONF" <<SERVER

# peer: $name
# added: $(date -I) ($mode)
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
SERVER
    sync
    echo "added '$name' -> $ip ($mode tunnel)"
    show_peer "$name"
    ;;

  show)
    name=${1:-}; [ -n "$name" ] || usage; show_peer "$name"
    ;;

  list)
    printf '%-16s %-14s %s\n' NAME TUNNEL-IP MODE
    awk '/^# peer: /{n=$3} /^# added: /{m=$NF} /^AllowedIPs/{sub("/32","",$3); printf "%-16s %-14s %s\n", n, $3, m}' "$CONF"
    ;;

  status)
    # wg show only knows public keys; join them back to names from the config.
    declare -A NAME
    while read -r n k; do NAME[$k]=$n; done < <(awk '/^# peer: /{n=$3} /^PublicKey/{print n, $3}' "$CONF")
    printf '%-16s %-14s %-22s %-10s %s\n' NAME TUNNEL-IP FROM HANDSHAKE TRANSFER
    wg show "$WG_IF" dump | tail -n +2 | while IFS=$'\t' read -r pub _ ep allowed hs rx tx _; do
      if [ "$hs" -gt 0 ]; then age=$(( $(date +%s) - hs )); hsfmt="${age}s ago"; [ "$age" -gt 180 ] && hsfmt="$((age/60))m ago"; else hsfmt=never; fi
      printf '%-16s %-14s %-22s %-10s %s\n' "${NAME[$pub]:-?}" "${allowed%/32}" "${ep/(none)/-}" "$hsfmt" "$(numfmt --to=iec "$rx")↓ $(numfmt --to=iec "$tx")↑"
    done
    ;;

  remove)
    name=${1:-}; [ -n "$name" ] || usage
    has_peer "$name" || { echo "no such peer: $name" >&2; exit 1; }
    # Drop the block from '# peer: NAME' up to (not including) the next blank line.
    tmp=$(mktemp); awk -v n="# peer: $name" '
      $0==n {skip=1; next}
      skip && /^$/ {skip=0}
      !skip' "$CONF" > "$tmp"
    # awk leaves the blank line that preceded the block; collapse doubles.
    cat -s "$tmp" > "$CONF"; rm -f "$tmp"
    rm -f "$PEERS/$name.conf"
    sync
    echo "removed '$name' (its key is gone; the device can no longer connect)"
    ;;

  *) usage ;;
esac
