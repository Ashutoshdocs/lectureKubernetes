#!/usr/bin/env bash
# Compare the certificate in three places, so you can see a renewal flow
# through end to end:
#
#   1. on disk   (what certbot has)
#   2. in the cluster Secret (what the Gateway is told to use)
#   3. live on the Gateway   (what browsers actually receive)
#
# Usage:  ./scripts/cert-status.sh [gateway-ip]
#   Without an IP it connects to the domain name through normal DNS.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need openssl kubectl

show() {
  # prints serial, issuer and expiry of a PEM certificate on stdin
  openssl x509 -noout -serial -issuer -enddate 2>/dev/null \
    | sed -e 's/^/    /' || echo "    (none)"
}

echo "1. On disk  ($CERTBOT_DIR/config/live/$CERT_NAME)"
LOCAL="$CERTBOT_DIR/config/live/$CERT_NAME/fullchain.pem"
if [[ -f "$LOCAL" ]]; then show < "$LOCAL"; else echo "    (none)"; fi

echo "2. Secret   ($K8S_NAMESPACE/$K8S_SECRET)"
kctl get secret "$K8S_SECRET" -n "$K8S_NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
  | base64 -d 2>/dev/null | show

TARGET="${1:-$CERT_NAME}"
echo "3. Live     ($TARGET:443, SNI $CERT_NAME)"
echo | timeout 10 openssl s_client -connect "$TARGET:443" -servername "$CERT_NAME" 2>/dev/null \
  | show
