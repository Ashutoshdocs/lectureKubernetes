#!/usr/bin/env bash
# Get a Let's Encrypt certificate with certbot (DNS-01 on Azure DNS) and load
# it into the cluster as the Gateway's TLS Secret.
#
# Usage:
#   ./scripts/issue-cert.sh
#
# Reads its settings from cert.env. With STAGING=1 you get an untrusted test
# certificate; switch to STAGING=0 and run again for the real one. The switch
# is detected automatically and forces a fresh certificate.
#
# Why DNS-01? Let's Encrypt proves you own the domain by checking a TXT
# record, not by calling your server. So the certificate can be issued before
# the Gateway, the public IP or the A record exist, and wildcards work too.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need certbot az kubectl openssl

# Is az logged in, and can it see the zone?
if ! az account show -o none 2>/dev/null; then
  echo "ERROR: az CLI is not logged in. Run 'az login' first." >&2
  exit 1
fi
if ! az_dns zone show -g "$DNS_RG" -n "$DNS_ZONE" -o none 2>/dev/null; then
  echo "ERROR: can't read DNS zone '$DNS_ZONE' in resource group '$DNS_RG'." >&2
  echo "       Check DNS_RG / DNS_ZONE / AZ_SUBSCRIPTION in cert.env, and that you" >&2
  echo "       have the 'DNS Zone Contributor' role on the zone." >&2
  exit 1
fi

DOMAIN_ARGS=()
IFS=',' read -ra DOMAINS <<< "$CERT_DOMAINS"
for d in "${DOMAINS[@]}"; do
  d="$(echo "$d" | xargs)"   # trim spaces
  [[ -n "$d" ]] && DOMAIN_ARGS+=(-d "$d")
done

EXTRA_ARGS=()
LIVE_CERT="$CERTBOT_DIR/config/live/$CERT_NAME/fullchain.pem"
if [[ -n "${ACME_SERVER:-}" ]]; then
  EXTRA_ARGS+=(--server "$ACME_SERVER")
  echo ">> Using ACME server $ACME_SERVER"
elif [[ "$STAGING" == "1" ]]; then
  EXTRA_ARGS+=(--test-cert)
  echo ">> Using Let's Encrypt STAGING (test certificate, browsers will warn)"
else
  echo ">> Using Let's Encrypt PRODUCTION"
  # Moving from a staging cert to production: certbot would otherwise say the
  # existing cert "is not yet due for renewal" and keep the untrusted one.
  if [[ -f "$LIVE_CERT" ]] && openssl x509 -in "$LIVE_CERT" -noout -issuer | grep -qi 'staging'; then
    echo ">> Existing certificate is from staging; forcing a new production one"
    EXTRA_ARGS+=(--force-renewal)
  fi
fi

mkdir -p "$CERTBOT_DIR"
chmod 700 "$CERTBOT_DIR"

echo ">> Requesting certificate '$CERT_NAME' for: $CERT_DOMAINS"
certbot certonly "${CERTBOT_ARGS[@]}" \
  --non-interactive \
  --agree-tos \
  --email "$CERT_EMAIL" \
  --cert-name "$CERT_NAME" \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook    "$ROOT/scripts/hooks/azure-dns-auth.sh" \
  --manual-cleanup-hook "$ROOT/scripts/hooks/azure-dns-cleanup.sh" \
  --key-type ecdsa \
  "${EXTRA_ARGS[@]}" \
  "${DOMAIN_ARGS[@]}"

echo ">> Loading certificate into Kubernetes"
"$ROOT/scripts/load-cert-secret.sh"

echo
echo "Done. Renew later with: ./scripts/renew-cert.sh"
