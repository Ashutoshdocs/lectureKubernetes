#!/usr/bin/env bash
# watch-scaling.sh — live view of KEDA scaling behaviour. Ctrl-C to stop.
# Shows the Redis queue length, worker replicas, the KEDA-managed HPA, and pods.
set -uo pipefail

while true; do
  clear
  echo "==== $(date '+%H:%M:%S')  KEDA scaling monitor ===="
  echo
  echo "Queue length (LLEN tasks):"
  kubectl exec deploy/redis -- redis-cli LLEN tasks 2>/dev/null || echo "  (redis not ready)"
  echo
  echo "Worker deployment (READY/UP-TO-DATE/AVAILABLE):"
  kubectl get deploy worker --no-headers 2>/dev/null || echo "  (not found)"
  echo
  echo "KEDA-managed HPA:"
  kubectl get hpa keda-hpa-worker-scaler --no-headers 2>/dev/null || echo "  (not created yet)"
  echo
  echo "ScaledObject (READY / ACTIVE):"
  kubectl get scaledobject worker-scaler --no-headers 2>/dev/null || echo "  (not found)"
  echo
  echo "Worker pods:"
  kubectl get pods -l app=worker --no-headers 2>/dev/null || echo "  (none)"
  sleep 2
done
