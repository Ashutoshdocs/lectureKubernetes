#!/usr/bin/env bash
# Apply all manifests in order and wait for everything to come up.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Applying manifests"
kubectl apply -f manifests/

echo "==> Waiting for MySQL"
kubectl -n arcade rollout status deploy/mysql --timeout=180s

echo "==> Waiting for backend"
kubectl -n arcade rollout status deploy/backend --timeout=120s

echo "==> Waiting for frontend"
kubectl -n arcade rollout status deploy/frontend --timeout=120s

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo
echo "======================================================"
echo "  App is up. Open it at:"
echo "     http://${NODE_IP}:30080"
echo "  (minikube users: run 'minikube service frontend -n arcade --url')"
echo "======================================================"
