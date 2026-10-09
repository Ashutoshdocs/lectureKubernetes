#!/usr/bin/env bash
# Writes one row per second through the LoadBalancer so you can SEE the outage
# window during failover. Usage: ./scripts/write-loop.sh  (Ctrl+C to stop)
set -uo pipefail
NS=${NS:-pg-demo}
IP=${FRONTEND_IP:-$(kubectl -n "$NS" get svc frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}')}
[ -n "$IP" ] || { echo "No LoadBalancer IP yet"; exit 1; }
echo "Writing to http://$IP/api/write every second..."
i=0
while true; do
  i=$((i+1))
  out=$(curl -s -m 5 -X POST "http://$IP/api/write" -H 'Content-Type: application/json' \
        -d "{\"body\":\"tick-$i $(date +%T)\"}")
  echo "$(date +%T) $out"
  sleep 1
done
