#!/usr/bin/env bash
# certbot --manual-cleanup-hook: removes the TXT value the auth hook added.
# When the last value goes, Azure deletes the empty _acme-challenge record set.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/../common.sh"

: "${CERTBOT_DOMAIN:?must be run by certbot}"
: "${CERTBOT_VALIDATION:?must be run by certbot}"

if [[ "$CERTBOT_DOMAIN" == "$DNS_ZONE" ]]; then
  RECORD="_acme-challenge"
else
  RECORD="_acme-challenge.${CERTBOT_DOMAIN%."${DNS_ZONE}"}"
fi

echo "[cleanup] removing TXT _acme-challenge.${CERTBOT_DOMAIN}"
az_dns record-set txt remove-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$RECORD" \
  --value "$CERTBOT_VALIDATION" -o none \
  || echo "[cleanup] record already gone"
