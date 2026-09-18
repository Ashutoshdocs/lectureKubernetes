#!/usr/bin/env bash
# =============================================================================
# verify.sh - deploy the 3-backend demo and prove inside<->outside reflection.
#   ./verify.sh setup        # namespace + NFS server
#   ./verify.sh hostpath     # PVC#1 + pod-a/pod-b, prove cross-pod + node<->pod
#   ./verify.sh nfs          # PVC#2 + pod-c, prove server<->pod
#   ./verify.sh azure        # Azure File CSI (needs AKS)
#   ./verify.sh mounts       # show mount points for every pod
#   ./verify.sh clean
# =============================================================================
set -euo pipefail
NS=pv-types
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ready(){ kubectl -n "$NS" wait --for=condition=Ready pod "$1" --timeout="${2:-120s}" || true; }

setup(){
  kubectl apply -f "$here/00-namespace.yaml"
  kubectl apply -f "$here/20-nfs/nfs-server.yaml"
  kubectl -n "$NS" wait --for=condition=Ready pod -l app=nfs-server --timeout=180s || true
}

hostpath(){
  say "hostPath: PVC#1 shared by pod-a and pod-b"
  kubectl apply -f "$here/10-hostpath/hostpath-pv-pvc.yaml"
  kubectl apply -f "$here/10-hostpath/hostpath-pods.yaml"
  ready pod/pod-a; ready pod/pod-b
  say "PROOF 1: write INSIDE pod-a -> read INSIDE pod-b"
  kubectl -n "$NS" exec pod-a -- sh -c 'echo "from pod-a @ $(date -u)" > /data/shared.txt'
  kubectl -n "$NS" exec pod-b -- cat /data/shared.txt
  say "PROOF 2: write from OUTSIDE (the node dir) -> read INSIDE pod-a"
  node=$(kubectl -n "$NS" get pod pod-a -o jsonpath='{.spec.nodeName}')
  echo "node hosting pod-a: $node"
  echo "  If kind:     docker exec $node sh -c 'echo from-node >> /mnt/data/hostpath-demo/shared.txt'"
  echo "  If minikube: minikube ssh -- 'sudo sh -c \"echo from-node >> /mnt/data/hostpath-demo/shared.txt\"'"
  echo "  then: kubectl -n $NS exec pod-a -- cat /data/shared.txt"
}

nfs(){
  say "NFS: PVC#2 used by pod-c (3rd pod)"
  kubectl apply -f "$here/20-nfs/nfs-pv-pvc-pod.yaml"
  ready pod/pod-c
  say "PROOF 3: write INSIDE pod-c -> read OUTSIDE on the NFS server export"
  kubectl -n "$NS" exec pod-c -- sh -c 'echo "from pod-c @ $(date -u)" > /data/hello.txt'
  srv=$(kubectl -n "$NS" get pod -l app=nfs-server -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" exec "$srv" -- cat /exports/hello.txt
  say "PROOF 4: write OUTSIDE (on NFS server) -> read INSIDE pod-c"
  kubectl -n "$NS" exec "$srv" -- sh -c 'echo "from nfs-server @ $(date -u)" > /exports/reverse.txt'
  kubectl -n "$NS" exec pod-c -- cat /data/reverse.txt
}

azure(){
  say "Azure File CSI (requires AKS / azure file csi driver)"
  kubectl apply -f "$here/30-azure-csi/azurefile-csi.yaml"
  ready pod/pod-azure 180s
  kubectl -n "$NS" get pvc azurefile-pvc
  kubectl -n "$NS" exec pod-azure -- sh -c 'cat /data/from-pod.txt' || true
  echo "OUTSIDE proof: view the share in the Azure Portal (Storage account -> File shares),"
  echo "or: az storage file list --account-name <acct> --share-name <share>"
}

mounts(){
  say "Mount points inside each pod (grep for /data)"
  for p in pod-a pod-b pod-c pod-azure; do
    if kubectl -n "$NS" get pod "$p" >/dev/null 2>&1; then
      echo "----- $p -----"
      kubectl -n "$NS" exec "$p" -- sh -c 'mount | grep " /data " || cat /proc/mounts | grep " /data "' 2>/dev/null || echo "(not running)"
      kubectl -n "$NS" exec "$p" -- df -h /data 2>/dev/null || true
    fi
  done
  say "PV/PVC overview"
  kubectl -n "$NS" get pvc
  kubectl get pv | grep -E 'hostpath|nfs|azure' || true
}

clean(){
  kubectl delete namespace "$NS" --ignore-not-found
  kubectl delete pv hostpath-pv nfs-pv azuredisk-pv --ignore-not-found
}

case "${1:-}" in
  setup) setup ;;
  hostpath) hostpath ;;
  nfs) nfs ;;
  azure) azure ;;
  mounts) mounts ;;
  clean) clean ;;
  *) grep -E '^#   \./verify' "$0" | sed 's/^# //'; exit 1 ;;
esac
