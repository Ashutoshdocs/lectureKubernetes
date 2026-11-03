#!/bin/bash
# =====================================================================
# 03-watch-cluster.sh   (HA VM, root)
#     sudo bash 03-watch-cluster.sh
#
# Live view (every 5s) used during the failover demo:
#   etcd leader / followers / down members, Raft TERM (increments on every
#   election), controller-manager + scheduler lease holders, node status.
# Ctrl+C to exit.
# =====================================================================
source "$(dirname "$0")/etcd-env.sh"

while true; do
  OUT=$(
    echo "=== $(date +%H:%M:%S)   watching from $(hostname)   (Ctrl+C to exit) ==="
    echo ""
    echo "--- etcd ---"
    status_table
    UP=$(for ep in $(member_endpoints); do ep_up "$ep" && echo up; done | grep -c up)
    TOTAL=$(member_endpoints | grep -c .)
    echo ""
    echo "Members up: ${UP}/${TOTAL}   quorum needs $(( TOTAL / 2 + 1 ))   -> $([ "$UP" -ge $(( TOTAL / 2 + 1 )) ] && echo 'HAS QUORUM (writes OK)' || echo 'NO QUORUM (read-only!)')"
    echo ""
    echo "--- leader election (Lease objects) ---"
    echo "kube-controller-manager : $(lease_holder kube-controller-manager)"
    echo "kube-scheduler          : $(lease_holder kube-scheduler)"
    echo ""
    echo "--- HAProxy backends (${LB_NAME}) ---"
    haproxy_backends
    echo ""
    echo "--- nodes ---"
    kubectl get nodes --request-timeout=4s 2>&1
  )
  clear
  echo "$OUT"
  sleep 5
done
