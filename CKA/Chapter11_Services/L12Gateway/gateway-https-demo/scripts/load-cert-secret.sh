#!/usr/bin/env bash
# Load the current certbot certificate into Kubernetes as a TLS Secret.
#
# Run by issue-cert.sh after the first issuance, and by renew-cert.sh as
# certbot's --deploy-hook after every successful renewal. Safe to run by hand
# at any time: it creates the Secret or updates it in place.
#
# The Gateway watches the Secret, so new certificates go live without
# restarting anything.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need kubectl openssl

# certbot sets RENEWED_LINEAGE when it runs this as a deploy hook.
LIVE_DIR="${RENEWED_LINEAGE:-$CERTBOT_DIR/config/live/$CERT_NAME}"
CERT="$LIVE_DIR/fullchain.pem"
KEY="$LIVE_DIR/privkey.pem"

if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  echo "ERROR: no certificate in $LIVE_DIR. Run ./scripts/issue-cert.sh first." >&2
  exit 1
fi

# The namespace may not exist yet if the manifests haven't been applied.
kctl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kctl apply -f - >/dev/null

kctl create secret tls "$K8S_SECRET" \
  --namespace "$K8S_NAMESPACE" \
  --cert "$CERT" \
  --key "$KEY" \
  --dry-run=client -o yaml \
  | kctl apply -f -

echo "Secret $K8S_NAMESPACE/$K8S_SECRET now holds:"
openssl x509 -in "$CERT" -noout -ext subjectAltName -issuer -enddate \
  | grep -v 'Subject Alternative Name' | sed -e 's/^ *//' -e 's/^/  /'
