#!/usr/bin/env bash
# Demo 1 cleanup
set -euo pipefail
NS="auth-demo"
echo "==> Removing RBAC, ServiceAccount, kubeconfig"
kubectl delete -f "$(dirname "$0")/../rbac/token-rbac.yaml" --ignore-not-found
kubectl delete serviceaccount token-user -n "${NS}" --ignore-not-found
rm -f /tmp/token-user.kubeconfig
echo "==> (Namespace '${NS}' is shared with Demo 2 — delete it only via the"
echo "    top-level cleanup, or run: kubectl delete namespace ${NS})"
echo "Done."
