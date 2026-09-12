#!/usr/bin/env bash
# Full teardown of everything both demos created.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="auth-demo"
bash "${HERE}/01-serviceaccount-token/cleanup.sh" || true
bash "${HERE}/02-client-certificate/cleanup.sh" || true
echo "==> Deleting shared namespace '${NS}' (removes the seed pod too)"
kubectl delete namespace "${NS}" --ignore-not-found
echo "All clean."
