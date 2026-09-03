#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prints, side by side, the resources currently requested by the pod(s) and
# the Target recommendation VPA has calculated. Run it repeatedly (or with
# `watch`) to see the numbers converge.
#
#   ./watch.sh          # print once
#   watch -n 5 ./watch.sh   # refresh every 5s (Linux/macOS)
# ---------------------------------------------------------------------------
set -euo pipefail

echo "== Pod resource requests =="
kubectl get pods -l app=vpa-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{.spec.containers[0].resources.requests}{"\n"}{end}'

echo
echo "== VPA target recommendation =="
kubectl get vpa vpa-demo \
  -o jsonpath='{.status.recommendation.containerRecommendations[*].target}'
echo
