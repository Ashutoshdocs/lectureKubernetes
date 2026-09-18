#!/usr/bin/env bash
# load-tasks.sh — push N tasks onto the Redis "tasks" list to trigger KEDA.
# Usage: ./load-tasks.sh [count]      (default: 50)
set -euo pipefail

COUNT="${1:-50}"

echo "Pushing $COUNT tasks onto the 'tasks' queue..."
for i in $(seq 1 "$COUNT"); do
  kubectl exec deploy/redis -- redis-cli LPUSH tasks "task$i" >/dev/null
done

LEN=$(kubectl exec deploy/redis -- redis-cli LLEN tasks)
echo "Done. Queue length is now: $LEN"
echo
echo "Now watch the workers spin up:"
echo "  kubectl get deploy worker -w"
echo "  ./watch-scaling.sh"
