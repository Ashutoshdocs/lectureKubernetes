#!/usr/bin/env bash
#
# RBAC ServiceAccount demo.
#
# Applies the manifests, waits for the pods, then proves three things:
#   1. The "creator" pod (bound to a Role) CAN create pods.
#   2. That same pod CANNOT delete pods (the Role has no "delete" verb).
#   3. The "nopowerhere" pod (default SA) CANNOT even list pods.
#
# Requires: a working kubectl pointed at any cluster (kind, minikube, k3s, EKS...).

set -euo pipefail

NS="practical"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

step "Applying manifests"
kubectl apply -f "$DIR/manifests"

step "Waiting for the demo pods to be Ready"
kubectl -n "$NS" wait --for=condition=Ready pod/creator     --timeout=120s
kubectl -n "$NS" wait --for=condition=Ready pod/nopowerhere --timeout=120s

# ---------------------------------------------------------------------------
step "TEST 1  |  creator (SA: pod-creator) creates a pod  ->  expect SUCCESS"
if kubectl -n "$NS" exec -i creator -- kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: created-by-serviceaccount
  namespace: practical
spec:
  containers:
    - name: nginx
      image: nginx
EOF
then
  green "PASS: creator was allowed to create a pod."
else
  red   "FAIL (unexpected): creator could not create a pod."
fi

# ---------------------------------------------------------------------------
step "TEST 2  |  creator tries to DELETE that pod  ->  expect FORBIDDEN"
if kubectl -n "$NS" exec creator -- kubectl delete pod created-by-serviceaccount 2>&1; then
  red   "FAIL (unexpected): creator was allowed to delete."
else
  green "PASS: creator was correctly forbidden from deleting (Role has no 'delete')."
fi

# ---------------------------------------------------------------------------
step "TEST 3  |  nopowerhere (default SA) lists pods  ->  expect FORBIDDEN"
if kubectl -n "$NS" exec nopowerhere -- kubectl get pods 2>&1; then
  red   "FAIL (unexpected): nopowerhere was allowed to list pods."
else
  green "PASS: nopowerhere was correctly forbidden (default SA has no Role)."
fi

step "Done"
echo "Pods currently in the '$NS' namespace:"
kubectl -n "$NS" get pods
echo
echo "Run ./cleanup.sh to remove everything."
