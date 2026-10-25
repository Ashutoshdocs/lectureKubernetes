#!/usr/bin/env bash
# =============================================================================
# demo.sh - prove hostPath vs emptyDir differences.
#   ./demo.sh up        # create namespace + all pods
#   ./demo.sh emptydir  # PROOF: emptyDir data dies with the pod
#   ./demo.sh hostpath  # PROOF: hostPath data survives pod delete + is shared
#   ./demo.sh clean
# =============================================================================
set -euo pipefail
NS=vol-demo
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ready(){ kubectl -n "$NS" wait --for=condition=Ready pod "$1" --timeout=120s || true; }

up(){
  kubectl apply -f "$here/00-namespace.yaml"
  kubectl apply -f "$here/10-emptydir-pod.yaml"
  kubectl apply -f "$here/20-hostpath-pod.yaml"
  kubectl apply -f "$here/21-hostpath-pod2.yaml"
  ready pod/emptydir-pod; ready pod/hostpath-pod; ready pod/hostpath-pod2
  kubectl -n "$NS" get pods -o wide
}

emptydir(){
  say "emptyDir: write a file inside the pod"
  kubectl -n "$NS" exec emptydir-pod -- sh -c 'echo "scratch data $(date -u)" > /data/file.txt; cat /data/file.txt'
  say "Delete the pod and recreate it (same spec)"
  kubectl -n "$NS" delete pod emptydir-pod
  kubectl apply -f "$here/10-emptydir-pod.yaml"; ready pod/emptydir-pod
  say "PROOF: the file is GONE - emptyDir was wiped with the old pod"
  kubectl -n "$NS" exec emptydir-pod -- sh -c 'ls -l /data; echo "---"; cat /data/file.txt 2>&1 || echo "file.txt no longer exists (expected)"'
}

hostpath(){
  say "hostPath: write a file inside hostpath-pod"
  kubectl -n "$NS" exec hostpath-pod -- sh -c 'echo "node data $(date -u)" > /data/file.txt; cat /data/file.txt'
  say "PROOF A (sharing): a DIFFERENT pod on the node sees the same file"
  kubectl -n "$NS" exec hostpath-pod2 -- cat /data/file.txt
  say "Delete hostpath-pod and recreate it (same spec)"
  kubectl -n "$NS" delete pod hostpath-pod
  kubectl apply -f "$here/20-hostpath-pod.yaml"; ready pod/hostpath-pod
  say "PROOF B (persistence): the file SURVIVED the pod deletion"
  kubectl -n "$NS" exec hostpath-pod -- cat /data/file.txt
  say "Where it physically lives on the node:"
  node=$(kubectl -n "$NS" get pod hostpath-pod -o jsonpath='{.spec.nodeName}')
  echo "  node=$node  path=/mnt/data/hostpath-demo"
  echo "  kind:     docker exec $node ls -l /mnt/data/hostpath-demo"
  echo "  minikube: minikube ssh -- 'sudo ls -l /mnt/data/hostpath-demo'"
}

clean(){ kubectl delete namespace "$NS" --ignore-not-found; }

case "${1:-}" in
  up) up ;;
  emptydir) emptydir ;;
  hostpath) hostpath ;;
  clean) clean ;;
  *) grep -E '^#   \./demo' "$0" | sed 's/^# //'; exit 1 ;;
esac
