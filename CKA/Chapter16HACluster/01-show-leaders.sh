#!/bin/bash
# =====================================================================
# 01-show-leaders.sh   (HA VM, root)   sudo bash 01-show-leaders.sh
#
# In Kubernetes there is no single "primary control plane". Three things
# elect a leader independently:
#   1. etcd                     -> Raft LEADER (all writes go through it)
#   2. kube-controller-manager  -> Lease kube-system/kube-controller-manager
#   3. kube-scheduler           -> Lease kube-system/kube-scheduler
# kube-apiserver is ACTIVE on all 3 (HAProxy spreads requests).
# =====================================================================
source "$(dirname "$0")/etcd-env.sh"

echo "================= etcd MEMBERS ================="
etcdctl --endpoints="$ALL_EPS" member list -w table

echo "================= etcd STATUS (who is LEADER) ================="
status_table

echo ""
echo "================= etcd HEALTH ================="
for ep in $(member_endpoints); do
  etcdctl --endpoints="$ep" endpoint health 2>&1 | sed 's/^/  /' | head -1
done

LEADER_EP=$(leader_endpoint)
LEADER_IP=$(ep_ip "$LEADER_EP")
echo ""
echo "================= WHO IS 'PRIMARY'? ================="
printf "  %-26s %s\n" "etcd Raft LEADER:"          "$(ip_to_name "$LEADER_IP")  ($LEADER_EP)"
printf "  %-26s %s\n" "kube-controller-manager:"   "$(lease_holder kube-controller-manager)"
printf "  %-26s %s\n" "kube-scheduler:"            "$(lease_holder kube-scheduler)"
printf "  %-26s %s\n" "kube-apiserver:"            "active on ALL control planes (HAProxy on ${LB_NAME} spreads requests)"
echo ""
echo "  All other etcd members are FOLLOWERS (secondary). They hold a full copy"
echo "  of the data and forward writes to the leader."
echo ""
echo "================= HAProxy backends (${LB_NAME}) ================="
haproxy_backends
echo ""
echo "================= NODES ================="
kubectl get nodes -o wide
