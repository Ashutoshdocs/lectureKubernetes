#!/usr/bin/env bash
# Puts the cluster back to the clean demo baseline:
# deletes demo workloads, uncordons all nodes, removes demo taints/labels, re-applies base labels.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> Deleting demo namespace (all demo workloads)"
kubectl delete namespace scheduling-demo --ignore-not-found --wait=true

WORKERS="worker-a1 worker-a2 worker-a3 worker-b1 worker-b2"
for n in $WORKERS; do
  kubectl uncordon "$n" >/dev/null
  kubectl taint nodes "$n" dedicated- 2>/dev/null || true
  kubectl taint nodes "$n" maintenance- 2>/dev/null || true
  kubectl label node "$n" env- team- 2>/dev/null || true
done

"$DIR/label-nodes.sh"
kubectl apply -f "$DIR/../manifests/00-namespace.yaml"
echo ">> Reset complete"
