#!/usr/bin/env bash
#
# Applies the demo and waits for both workloads to roll out.
set -euo pipefail

NS="acme-prod"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

step "Applying manifests (namespace, RBAC, workloads)"
kubectl apply -f "$DIR/manifests"

step "Waiting for rollouts"
kubectl -n "$NS" rollout status deploy/web-app  --timeout=120s
kubectl -n "$NS" rollout status deploy/reporter --timeout=120s

step "Current state"
kubectl -n "$NS" get sa,role,rolebinding,deploy,pods

cat <<EOF

Setup complete.

Watch the reporter do its job (it lists pods + reads app-config every 30s):
  kubectl -n $NS logs deploy/reporter -f

Then run the checks:
  ./scripts/02-verify.sh          # what each identity CAN do
  ./scripts/03-negative-tests.sh  # what the reporter is correctly DENIED
EOF
