#!/usr/bin/env bash
# Demo 2 cleanup
set -euo pipefail
NS="auth-demo"
WORKDIR="$(cd "$(dirname "$0")" && pwd)/pki"
echo "==> Removing RBAC, CSR object, generated PKI, kubeconfig"
kubectl delete -f "$(dirname "$0")/../rbac/cert-rbac.yaml" --ignore-not-found
kubectl delete csr cert-user-csr --ignore-not-found
rm -rf "${WORKDIR}"
rm -f /tmp/cert-user.kubeconfig
echo "==> (Namespace '${NS}' is shared with Demo 1 — delete via top-level cleanup,"
echo "    or run: kubectl delete namespace ${NS})"
echo "Done."
echo
echo "Reminder: the issued cert stays valid until it EXPIRES. Deleting the CSR"
echo "object and RBAC removes authorization, but the cert would still authenticate"
echo "(as an unauthorized user) until expiry. This is the core cert trade-off."
