#!/usr/bin/env bash
# One-shot view of the whole cluster state: who is primary, who replicates from whom.
set -uo pipefail
NS=${NS:-pg-demo}
k() { kubectl -n "$NS" "$@"; }
sql() { k exec "$1" -- psql -U postgres -d appdb -Atc "$2" 2>/dev/null; }

echo "=== ConfigMap pg-cluster: PRIMARY_INSTANCE = $(k get cm pg-cluster -o jsonpath='{.data.PRIMARY_INSTANCE}')"
echo
echo "=== Service selectors -> endpoints"
for svc in pg-primary pg-replica; do
  sel=$(k get svc "$svc" -o jsonpath='{.spec.selector.instance}')
  eps=$(k get endpoints "$svc" -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}({.ip}) {end}')
  printf "  %-11s selector instance=%-5s endpoints: %s\n" "$svc" "$sel" "${eps:-<none - no ready pod>}"
done
echo
echo "=== Pods"
k get pods -l app=pg -o wide
echo
for pod in pg-a-0 pg-b-0; do
  phase=$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ -z "$phase" ]; then echo "--- $pod: not present (scaled to 0?)"; continue; fi
  rec=$(sql "$pod" "SELECT pg_is_in_recovery();")
  if [ -z "$rec" ]; then echo "--- $pod: postgres NOT answering"; continue; fi
  role=$([ "$rec" = "t" ] && echo "REPLICA (in recovery)" || echo "PRIMARY")
  rows=$(sql "$pod" "SELECT count(*) FROM messages;")
  last=$(sql "$pod" "SELECT id||' | '||body||' | written_on='||written_on FROM messages ORDER BY id DESC LIMIT 1;")
  tl=$(sql "$pod" "SELECT timeline_id FROM pg_control_checkpoint();")
  echo "--- $pod: $role | timeline=$tl | rows=$rows | last: $last"
  if [ "$rec" = "f" ]; then
    echo "    pg_stat_replication (replicas streaming from me):"
    sql "$pod" "SELECT '      '||application_name||'  state='||state||'  sync='||sync_state||'  client='||client_addr FROM pg_stat_replication;" \
      | sed 's/^$/      <none>/'
  else
    sql "$pod" "SELECT '    receiving WAL from: '||sender_host||'  status='||status FROM pg_stat_wal_receiver;"
  fi
done
echo
echo "=== PVCs (access modes)"
k get pvc -o custom-columns=PVC:.metadata.name,STATUS:.status.phase,MODES:.spec.accessModes,CLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage
