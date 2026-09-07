#!/usr/bin/env bash
# Verify the DuckDNS + Caddy remote-access path, one link at a time.
# Run after filling in .env, starting the stack, and forwarding 80/443.
#   bash /mnt/calculon/media-stack/check-remote-access.sh
set -uo pipefail
cd "$(dirname "$0")"

ok(){ printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m??\033[0m   %s\n' "$1"; }

# Pull just the keys we need. Don't source .env wholesale -- values like
# PIA_REGION="CA Toronto" are unquoted and the shell would try to run them.
envget(){ sed -nE "s/^$1=(.*)$/\\1/p" ./.env | tail -1; }
DUCKDNS_SUBDOMAIN=$(envget DUCKDNS_SUBDOMAIN)
DUCKDNS_TOKEN=$(envget DUCKDNS_TOKEN)
HOST="${DUCKDNS_SUBDOMAIN}.duckdns.org"

echo "1. .env"
if [ -z "$DUCKDNS_SUBDOMAIN" ] || [ -z "${DUCKDNS_TOKEN:-}" ]; then
  bad "DUCKDNS_SUBDOMAIN / DUCKDNS_TOKEN not set in .env -- stop here"; exit 1
fi
ok "subdomain=$HOST"

echo "2. host firewall (ufw is active; host-networked Caddy is subject to it)"
if command -v ufw >/dev/null && sudo -n ufw status >/dev/null 2>&1; then
  for port in 80 443; do
    sudo -n ufw status | grep -qE "^${port}(/tcp)?\s+ALLOW" \
      && ok "ufw allows $port/tcp" \
      || bad "ufw is NOT allowing $port/tcp -- sudo ufw allow $port/tcp"
  done
else
  warn "need sudo to read ufw; check by hand:  sudo ufw status"
fi

echo "3. containers"
for c in duckdns caddy; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) \
    && [ "$st" = running ] && ok "$c running" || bad "$c not running ($st)"
done

echo "4. DNS"
PUBIP=$(curl -4 -s --max-time 8 https://ifconfig.me)
DNSIP=$(dig +short "$HOST" @1.1.1.1 | tail -1)
echo "     public IP = $PUBIP / DuckDNS says $DNSIP"
[ -n "$DNSIP" ] && [ "$PUBIP" = "$DNSIP" ] \
  && ok "DuckDNS record matches this house's IP" \
  || bad "mismatch -- check 'docker logs duckdns'"

echo "5. wildcard subdomains"
for s in jellyfin requests; do
  [ "$(dig +short "$s.$HOST" @1.1.1.1 | tail -1)" = "$DNSIP" ] \
    && ok "$s.$HOST resolves" || bad "$s.$HOST does not resolve"
done

echo "6. certificates (proof that inbound 80/443 reached us from the internet)"
if docker logs caddy 2>&1 | grep -q "certificate obtained successfully"; then
  ok "Let's Encrypt issued certs -- port forwarding works"
  docker logs caddy 2>&1 | grep -o 'identifiers=\[[^]]*\]' | sort -u | sed 's/^/       /'
else
  warn "no 'certificate obtained successfully' yet"
  echo "       Caddy errors, if any:"
  docker logs caddy 2>&1 | grep -iE 'error|failed' | tail -5 | sed 's/^/       /'
fi

echo "7. end-to-end over HTTPS"
for u in "https://jellyfin.$HOST/health" "https://requests.$HOST/"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$u")
  case "$code" in
    200|30[0-9]) ok "$u -> $code" ;;
    000) warn "$u -> no answer (fine if your router lacks NAT loopback; test from cell data)" ;;
    *)   bad  "$u -> $code" ;;
  esac
done

echo "8. things that must NOT be public"
for p in 8989 7878 9696 6767 8080 8096; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$PUBIP:$p/")
  [ "$code" = "000" ] && ok "port $p closed from outside" \
    || bad "port $p ANSWERED ($code) -- remove that forward on the router"
done
