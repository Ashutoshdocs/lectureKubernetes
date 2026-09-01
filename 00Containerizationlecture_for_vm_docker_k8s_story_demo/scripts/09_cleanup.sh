#!/usr/bin/env bash
set -e
kubectl delete -f 03-k8s/k8s/service.yaml --ignore-not-found
kubectl delete -f 03-k8s/k8s/deployment.yaml --ignore-not-found
docker rm -f blueforge greenpulse 2>/dev/null || true
rm -rf 01-vm-two-apps/shared-env
echo "Cleanup complete."
