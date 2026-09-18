#!/bin/bash
# Issue an X.509 client certificate for a user.
# For cluster-role binding by USER we only need the CN (= Kubernetes username).
#
# Usage: ./generate-user-cert.sh <username> [days]
set -euo pipefail

USERNAME="${1:?Usage: ./generate-user-cert.sh <username> [days]}"
DAYS="${2:-90}"
PKI_DIR="/etc/kubernetes/pki"

cd "$PKI_DIR"

openssl genrsa -out "${USERNAME}.key" 2048

openssl req -new -key "${USERNAME}.key" -out "${USERNAME}.csr" \
  -subj "/CN=${USERNAME}"

openssl x509 -req -in "${USERNAME}.csr" \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out "${USERNAME}.crt" -days "${DAYS}"

chmod 600 "${USERNAME}.key"

echo "OK: certificate for user '${USERNAME}' (${DAYS}d) written to ${PKI_DIR}"
