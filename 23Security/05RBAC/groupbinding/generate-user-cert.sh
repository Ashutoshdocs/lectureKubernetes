#!/bin/bash
# Generate an X.509 client certificate for a user, placing them in a group.
#
#   CN (Common Name)  -> Kubernetes username
#   O  (Organization) -> Kubernetes group  (this is what group-binding keys on)
#
# Usage: ./generate-user-cert.sh <username> [group] [days]
set -euo pipefail

USERNAME="${1:?Usage: ./generate-user-cert.sh <username> [group] [days]}"
GROUP="${2:-dev}"
DAYS="${3:-90}"
PKI_DIR="/etc/kubernetes/pki"

cd "$PKI_DIR"

# 1. Private key
openssl genrsa -out "${USERNAME}.key" 2048

# 2. Certificate Signing Request  (CN=user, O=group)
openssl req -new -key "${USERNAME}.key" -out "${USERNAME}.csr" \
  -subj "/CN=${USERNAME}/O=${GROUP}"

# 3. Sign the CSR with the cluster CA
openssl x509 -req -in "${USERNAME}.csr" \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out "${USERNAME}.crt" -days "${DAYS}"

# Lock down the private key
chmod 600 "${USERNAME}.key"

echo "OK: certificate for '${USERNAME}' (group='${GROUP}', ${DAYS}d) written to ${PKI_DIR}"
