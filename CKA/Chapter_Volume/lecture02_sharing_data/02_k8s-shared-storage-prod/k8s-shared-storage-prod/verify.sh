#!/usr/bin/env bash
# =============================================================================
# verify.sh - deploy and prove the production shared-storage demo.
#   ./verify.sh up       # namespace + NFS + PVC + writer/reader
#   ./verify.sh prove    # show writers sharing + reader read-only enforcement
#   ./verify.sh harden   # show the security posture is actually applied
#   ./verify.sh clean
# =============================================================================
set -euo pipefail
NS=shared-storage
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

up(){
  kubectl apply -f "$here/00-namespace.yaml"
  kubectl apply -f "$here/10-storage/nfs-server.yaml"
  kubectl -n "$NS" wait --for=condition=Available deploy/nfs-server --timeout=180s || true
  kubectl apply -f "$here/10-storage/shared-pv-pvc.yaml"
  kubectl apply -f "$here/20-workloads/writer-deployment.yaml"
  kubectl apply -f "$here/20-workloads/reader-deployment.yaml"
  kubectl -n "$NS" rollout status deploy/writer --timeout=120s
  kubectl -n "$NS" rollout status deploy/reader --timeout=120s
  kubectl -n "$NS" get pvc,pods -o wide
}

prove(){
  say "PROOF 1: PVC is Bound (RWX)"
  kubectl -n "$NS" get pvc shared-pvc
  sleep 12
  say "PROOF 2: BOTH writer replicas append to the same file (RWX concurrency)"
  r=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=reader -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" exec "$r" -- sh -c 'echo "distinct writers seen:"; awk "{print \$4}" /shared/data.txt | sort -u; echo "--- last 6 lines ---"; tail -n 6 /shared/data.txt'
  say "PROOF 3: reader is READ-ONLY - a write must FAIL"
  kubectl -n "$NS" exec "$r" -- sh -c 'echo hack > /shared/data.txt 2>&1 || echo "EXPECTED: write blocked (Read-only file system)"'
}

harden(){
  w=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=writer -o jsonpath='{.items[0].metadata.name}')
  say "Security posture actually enforced on $w"
  kubectl -n "$NS" get pod "$w" -o jsonpath='{range .spec.containers[*]}runAsNonRoot={..securityContext.runAsNonRoot} roRootFS={.securityContext.readOnlyRootFilesystem} caps={.securityContext.capabilities.drop}{"\n"}{end}'
  say "Proof: cannot write to the root filesystem (readOnlyRootFilesystem)"
  kubectl -n "$NS" exec "$w" -- sh -c 'echo x > /oops 2>&1 || echo "EXPECTED: / is read-only"'
  say "Proof: running as uid 1000, not root"
  kubectl -n "$NS" exec "$w" -- id
}

clean(){
  kubectl delete namespace "$NS" --ignore-not-found
  kubectl delete pv shared-nfs-pv --ignore-not-found
}

case "${1:-}" in
  up) up ;;
  prove) prove ;;
  harden) harden ;;
  clean) clean ;;
  *) grep -E '^#   \./verify' "$0" | sed 's/^# //'; exit 1 ;;
esac
