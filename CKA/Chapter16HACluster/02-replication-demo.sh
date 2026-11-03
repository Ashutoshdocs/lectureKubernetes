#!/bin/bash
# =====================================================================
# 02-replication-demo.sh   (HA VM, root)
#     sudo bash 02-replication-demo.sh
#
# Proves every etcd member holds a full copy of the data:
#   A) write a plain key into etcd
#   B) create Kubernetes objects through the API
#   C) read both back from EACH member with --consistency=s
#      (serializable = answered from that member's LOCAL copy,
#       not forwarded to the leader)
# =====================================================================
source "$(dirname "$0")/etcd-env.sh"

LEADER_EP=$(leader_endpoint)
LEADER_IP=$(ep_ip "$LEADER_EP")
echo "Current etcd leader: $(ip_to_name "$LEADER_IP")"
echo ""

VALUE="written from $(hostname) at $(date +%H:%M:%S)"
FOLLOWER_EP=$(for ep in $(member_endpoints); do [ "$ep" != "$LEADER_EP" ] && ep_up "$ep" && echo "$ep"; done | head -1)
FOLLOWER_EP=${FOLLOWER_EP:-$LEADER_EP}
echo "=== A) etcdctl put /demo/message  -- sent to a FOLLOWER: $(ip_to_name "$(ep_ip "$FOLLOWER_EP")") ==="
echo "    The follower forwards the write to the leader; the leader commits it"
echo "    once a MAJORITY (2 of 3) has stored it, then all members apply it."
etcdctl --endpoints="$FOLLOWER_EP" put /demo/message "$VALUE"
echo ""

echo "=== B) create Kubernetes objects through the API ==="
kubectl create namespace ha-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ha-demo create configmap replication-proof \
  --from-literal=written-at="$(date +%H:%M:%S)" --from-literal=from="$(hostname)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ha-demo get deploy ha-web >/dev/null 2>&1 || \
  kubectl -n ha-demo create deployment ha-web --image=nginx:1.27 --replicas=3
echo ""

sleep 2
echo "=== C) read from EACH member's local copy ==="
for ep in $(member_endpoints); do
  echo "----- $(ip_to_name "$(ep_ip "$ep")")  ($ep)"
  if ! ep_up "$ep"; then
    echo "      DOWN / unreachable"; continue
  fi
  echo -n "      /demo/message            : "
  etcdctl --endpoints="$ep" get /demo/message --consistency=s --print-value-only
  echo -n "      configmap key in etcd    : "
  etcdctl --endpoints="$ep" get /registry/configmaps/ha-demo/replication-proof --consistency=s --keys-only | head -1
  echo -n "      deployment key in etcd   : "
  etcdctl --endpoints="$ep" get /registry/deployments/ha-demo/ha-web --consistency=s --keys-only | head -1
  echo -n "      total keys in this member: "
  etcdctl --endpoints="$ep" get / --prefix --keys-only --consistency=s | grep -c .
done
echo ""

echo "=== Same REVISION and RAFT-INDEX on every member = fully replicated ==="
status_table
echo ""
echo "Kubernetes object values are stored as protobuf, so we show only keys."
echo "Try:  etcdctl --endpoints=https://<ip>:2379 get /registry/configmaps/ha-demo/replication-proof --consistency=s"
