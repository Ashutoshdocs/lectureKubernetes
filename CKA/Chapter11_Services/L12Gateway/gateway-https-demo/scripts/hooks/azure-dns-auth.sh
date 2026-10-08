#!/usr/bin/env bash
# certbot --manual-auth-hook for the DNS-01 challenge on Azure DNS.
#
# certbot calls this once per domain with:
#   CERTBOT_DOMAIN       e.g. akblazeacademy.net  (wildcards arrive without "*.")
#   CERTBOT_VALIDATION   the token Let's Encrypt expects to find
#
# It adds a TXT record _acme-challenge.<domain> with that token, then waits
# until Azure's authoritative nameservers serve it, so Let's Encrypt sees it
# on the first try.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/../common.sh"

: "${CERTBOT_DOMAIN:?must be run by certbot}"
: "${CERTBOT_VALIDATION:?must be run by certbot}"

FQDN="_acme-challenge.${CERTBOT_DOMAIN}"
if [[ "$CERTBOT_DOMAIN" == "$DNS_ZONE" ]]; then
  RECORD="_acme-challenge"
elif [[ "$CERTBOT_DOMAIN" == *".${DNS_ZONE}" ]]; then
  RECORD="_acme-challenge.${CERTBOT_DOMAIN%."${DNS_ZONE}"}"
else
  echo "ERROR: $CERTBOT_DOMAIN is not inside the DNS zone $DNS_ZONE" >&2
  exit 1
fi

echo "[auth] adding TXT $FQDN in zone $DNS_ZONE"

# Create the record set with a short TTL if it doesn't exist yet. If it does
# exist (apex + wildcard share one name), leave it alone and just add a value.
if ! az_dns record-set txt show -g "$DNS_RG" -z "$DNS_ZONE" -n "$RECORD" -o none 2>/dev/null; then
  az_dns record-set txt create -g "$DNS_RG" -z "$DNS_ZONE" -n "$RECORD" --ttl 60 -o none
fi
az_dns record-set txt add-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$RECORD" \
  --value "$CERTBOT_VALIDATION" -o none

# Wait for the zone's own nameserver to serve the new value.
NS="$(az_dns zone show -g "$DNS_RG" -n "$DNS_ZONE" --query 'nameServers[0]' -o tsv | sed 's/\.$//')"

lookup() {
  if command -v dig >/dev/null 2>&1; then
    dig +short TXT "$FQDN" "@$NS"
  else
    nslookup -type=TXT "$FQDN" "$NS" 2>/dev/null
  fi
}

if command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1; then
  echo "[auth] waiting for $NS to serve the record"
  for _ in $(seq 1 36); do
    if lookup 2>/dev/null | grep -q -- "$CERTBOT_VALIDATION"; then
      echo "[auth] record is live"
      sleep 5   # small buffer for the other Azure nameservers
      exit 0
    fi
    sleep 5
  done
  echo "[auth] record not visible after 3 minutes; continuing anyway" >&2
else
  echo "[auth] neither dig nor nslookup found; waiting 60s for propagation"
  sleep 60
fi
