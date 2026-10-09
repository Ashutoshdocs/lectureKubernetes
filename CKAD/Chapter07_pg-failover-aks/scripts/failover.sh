#!/usr/bin/env bash
# Automates the manual failover from the README:
#   fence old primary -> promote replica -> update ConfigMap -> repoint Services
#   -> (optionally) rebuild old primary as the new replica.
# Usage:  ./scripts/failover.sh            # REBUILD=no ./scripts/failover.sh to skip the rebuild
set -euo pipefail
NS=${NS:-pg-demo}
REBUILD=${REBUILD:-yes}
k() { kubectl -n "$NS" "$@"; }

OLD=$(k get cm pg-cluster -o jsonpath='{.data.PRIMARY_INSTANCE}')
if [ "$OLD" = "pg-a" ]; then NEW=pg-b; else NEW=pg-a; fi
echo "Current primary: $OLD   ->   new primary: $NEW"

echo "[1/6] FENCE old primary (scale $OLD to 0) so it can never come back as a 2nd primary"
k scale sts "$OLD" --replicas=0
k wait --for=delete pod/"$OLD-0" --timeout=120s 2>/dev/null || true

echo "[2/6] PROMOTE $NEW-0"
if [ "$(k exec "$NEW-0" -- psql -U postgres -Atc 'SELECT pg_is_in_recovery();')" = "t" ]; then
  k exec "$NEW-0" -- psql -U postgres -Atc "SELECT pg_promote(wait => true);"
else
  echo "      $NEW-0 is already a primary, skipping promote"
fi

echo "[3/6] VERIFY pg_is_in_recovery() on $NEW-0 (expect f):"
k exec "$NEW-0" -- psql -U postgres -Atc "SELECT pg_is_in_recovery();"

echo "[4/6] UPDATE ConfigMap pg-cluster PRIMARY_INSTANCE=$NEW"
k patch cm pg-cluster --type merge -p "{\"data\":{\"PRIMARY_INSTANCE\":\"$NEW\"}}"

echo "[5/6] REPOINT Services: pg-primary -> $NEW, pg-replica -> $OLD"
k patch svc pg-primary --type merge -p "{\"spec\":{\"selector\":{\"app\":\"pg\",\"instance\":\"$NEW\"}}}"
k patch svc pg-replica --type merge -p "{\"spec\":{\"selector\":{\"app\":\"pg\",\"instance\":\"$OLD\"}}}"

if [ "$REBUILD" = "yes" ]; then
  echo "[6/6] REBUILD $OLD as a replica of $NEW (wipes its disk and re-clones)"
  k scale sts "$OLD" --replicas=1
  k rollout status sts "$OLD" --timeout=600s
else
  echo "[6/6] Skipped rebuild. Run: kubectl -n $NS scale sts $OLD --replicas=1"
fi

echo
echo "Done. Run ./scripts/status.sh to verify."
