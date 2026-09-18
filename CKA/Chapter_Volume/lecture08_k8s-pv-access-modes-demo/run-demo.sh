#!/usr/bin/env bash
# =============================================================================
# run-demo.sh - drive the whole PV access-modes demo end to end.
# Usage:
#   ./run-demo.sh setup     # namespace + NFS server
#   ./run-demo.sh rwx       # deploy + prove ReadWriteMany
#   ./run-demo.sh rox       # deploy + prove ReadOnlyMany
#   ./run-demo.sh rwo       # deploy + prove ReadWriteOnce (needs 2+ nodes for part B)
#   ./run-demo.sh rwop      # bonus: prove ReadWriteOncePod
#   ./run-demo.sh all       # setup + rwx + rox + rwo
#   ./run-demo.sh clean     # delete everything
# =============================================================================
set -euo pipefail
NS=pv-demo
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

wait_ready() { # wait_ready <label> [timeout]
  kubectl -n "$NS" wait --for=condition=Ready pod -l "$1" --timeout="${2:-120s}" || true
}

setup() {
  say "Creating namespace + NFS server"
  kubectl apply -f "$here/00-nfs-server/namespace.yaml"
  kubectl apply -f "$here/00-nfs-server/nfs-server.yaml"
  wait_ready "app=nfs-server" 180s
  kubectl -n "$NS" get pods -l app=nfs-server -o wide
}

rwx() {
  say "RWX: PV/PVC + 3 concurrent writers"
  kubectl apply -f "$here/10-rwx/rwx-pv-pvc.yaml"
  kubectl apply -f "$here/10-rwx/rwx-writers.yaml"
  wait_ready "app=rwx-writers" 120s
  say "PVC should be Bound:"; kubectl -n "$NS" get pvc rwx-nfs-pvc
  say "3 pods (ideally on different nodes):"; kubectl -n "$NS" get pods -l app=rwx-writers -o wide
  sleep 12
  say "PROOF: one shared file contains interleaved writes from ALL pods:"
  pod=$(kubectl -n "$NS" get pod -l app=rwx-writers -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" exec "$pod" -- sh -c 'echo "distinct pods that wrote:"; awk "{print \$4}" /data/shared.log | sort -u; echo "---- last 8 lines ----"; tail -n 8 /data/shared.log'
}

rox() {
  say "ROX: seed once (RW), then many read-only consumers"
  kubectl apply -f "$here/20-rox/rox-seed-job.yaml"
  kubectl -n "$NS" wait --for=condition=complete job/rox-seed --timeout=120s || true
  kubectl -n "$NS" logs job/rox-seed || true
  kubectl apply -f "$here/20-rox/rox-readers.yaml"
  wait_ready "app=rox-readers" 120s
  say "PROOF: readers can READ but every WRITE is blocked (Read-only file system):"
  for p in $(kubectl -n "$NS" get pod -l app=rox-readers -o jsonpath='{.items[*].metadata.name}'); do
    echo "----- $p -----"; kubectl -n "$NS" logs "$p"
  done
}

rwo() {
  say "RWO: part A - two pods on the SAME node share the volume (works)"
  kubectl apply -f "$here/30-rwo/rwo-pvc.yaml"
  kubectl apply -f "$here/30-rwo/rwo-A-same-node-two-pods.yaml"
  wait_ready "app=rwo-same-node" 120s
  kubectl -n "$NS" get pods -l app=rwo-same-node -o wide
  say "RWO: part B - a pod on ANOTHER node is blocked (needs 2+ nodes)"
  kubectl apply -f "$here/30-rwo/rwo-B-other-node-blocked.yaml"
  sleep 20
  kubectl -n "$NS" get pods -l app=rwo-other-node -o wide
  say "PROOF: describe shows the Multi-Attach error (if you have >1 node):"
  op=$(kubectl -n "$NS" get pod -l app=rwo-other-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$op" ] && kubectl -n "$NS" describe pod "$op" | grep -A3 -iE 'multi-attach|FailedAttach|Events' || echo "(single-node cluster: no other node to block on - that's expected)"
}

rwop() {
  say "BONUS RWOP: 2 replicas requested, only ONE can ever mount"
  kubectl apply -f "$here/40-bonus/rwop.yaml"
  sleep 15
  kubectl -n "$NS" get pods -l app=rwop-demo -o wide
  say "PROOF: exactly one Running, the other Pending on the volume:"
  pend=$(kubectl -n "$NS" get pod -l app=rwop-demo --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$pend" ] && kubectl -n "$NS" describe pod "$pend" | grep -iA2 'Events' || echo "(driver may not support RWOP, or scheduling still settling)"
}

clean() {
  say "Deleting namespace + PVs"
  kubectl delete namespace "$NS" --ignore-not-found
  kubectl delete pv rwx-nfs-pv rox-nfs-pv --ignore-not-found
}

case "${1:-}" in
  setup) setup ;;
  rwx)   rwx ;;
  rox)   rox ;;
  rwo)   rwo ;;
  rwop)  rwop ;;
  all)   setup; rwx; rox; rwo ;;
  clean) clean ;;
  *) grep -E '^#   \./run-demo' "$0" | sed 's/^# //'; exit 1 ;;
esac
