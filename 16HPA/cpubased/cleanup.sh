#!/usr/bin/env bash
#
# cleanup.sh — Remove everything this demo created.
#
set -euo pipefail

METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.8.1}"

echo "==> Deleting demo resources"
kubectl delete -f generator.yaml  --ignore-not-found
kubectl delete -f hpa.yaml        --ignore-not-found
kubectl delete -f service.yaml    --ignore-not-found
kubectl delete -f deployment.yaml --ignore-not-found

echo
echo "Demo resources removed."
echo "metrics-server was left installed (other things may rely on it)."
echo "To remove it too, run:"
echo "  kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
