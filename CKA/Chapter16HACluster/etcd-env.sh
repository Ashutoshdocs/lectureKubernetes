#!/bin/bash
# =====================================================================
# etcd-env.sh  -  sourced by the demo scripts. Run them on the HA VM
# (vm-k8s-lb) after HAVM-GetClusterAccess.sh. Also works on a control plane.
# Interactive use:   sudo -i; cd <this folder>; source etcd-env.sh
# =====================================================================
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_D}/cluster.env"

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

if [ -f /etc/k8s-demo/etcd/ca.crt ]; then            # HA VM
  CERT_DIR=/etc/k8s-demo/etcd
  export KUBECONFIG=/etc/k8s-demo/admin.conf
elif [ -f /etc/kubernetes/pki/etcd/ca.crt ]; then   # control plane
  CERT_DIR=/etc/kubernetes/pki/etcd
  export KUBECONFIG=/etc/kubernetes/admin.conf
else
  echo "No etcd certs found. On the HA VM run: bash HAVM-GetClusterAccess.sh"; exit 1
fi
command -v etcdctl >/dev/null || { echo "etcdctl missing. Run: bash HAVM-GetClusterAccess.sh"; exit 1; }

export ETCDCTL_API=3
export ETCDCTL_CACERT=${CERT_DIR}/ca.crt
export ETCDCTL_CERT=${CERT_DIR}/healthcheck-client.crt
export ETCDCTL_KEY=${CERT_DIR}/healthcheck-client.key
export ETCDCTL_COMMAND_TIMEOUT=3s
export ETCDCTL_DIAL_TIMEOUT=3s

# all control plane endpoints from cluster.env; etcdctl uses whichever answers
ALL_EPS=$(for n in ${CP_NODES}; do printf "https://%s:2379," "${n##*:}"; done | sed 's/,$//')

ip_to_name() {
  local ip=$1 n
  for n in ${LB_NAME}:${LB_IP} ${CP_NODES} ${WORKER_NODES} ${NEW_NODE_NAME}:${NEW_NODE_IP}; do
    [ "${n##*:}" = "$ip" ] && { echo "${n%%:*}"; return; }
  done
  echo "$ip"
}
ep_ip() { echo "$1" | sed -E 's#https://([^:]+):.*#\1#'; }

# all member client URLs known to etcd (includes stopped members)
member_endpoints() {
  local out
  out=$(etcdctl --endpoints="$ALL_EPS" member list -w json 2>/dev/null | jq -r '.members[].clientURLs[0]' 2>/dev/null)
  # no quorum -> member list fails; fall back to the list in cluster.env
  [ -n "$out" ] && echo "$out" || echo "$ALL_EPS" | tr ',' '\n'
}

ep_up() { etcdctl --endpoints="$1" endpoint health >/dev/null 2>&1; }

leader_endpoint() {
  local ep
  for ep in $(member_endpoints); do
    etcdctl --endpoints="$ep" endpoint status -w json 2>/dev/null \
      | jq -r '.[] | select(.Status.header.member_id == .Status.leader) | .Endpoint'
  done | head -1
}

lease_holder() {   # $1 = lease name in kube-system
  kubectl get lease -n kube-system "$1" -o jsonpath='{.spec.holderIdentity}' --request-timeout=4s 2>/dev/null | cut -d_ -f1
}

# one row per member: NAME ENDPOINT ROLE TERM RAFT-INDEX REVISION DB-SIZE VERSION
status_table() {
  local ep row
  printf "%-16s %-26s %-9s %-6s %-11s %-9s %-8s %s\n" NAME ENDPOINT ROLE TERM RAFT-INDEX REVISION DB-SIZE VERSION
  for ep in $(member_endpoints); do
    row=$(etcdctl --endpoints="$ep" endpoint status -w json 2>/dev/null | jq -r '.[0] |
      [ (if .Status.header.member_id == .Status.leader then "LEADER" else "follower" end),
        .Status.raftTerm, .Status.raftIndex, .Status.header.revision,
        ((.Status.dbSize/1024|floor|tostring)+"K"), .Status.version ] | @tsv')
    if [ -n "$row" ]; then
      printf "%-16s %-26s %-9s %-6s %-11s %-9s %-8s %s\n" "$(ip_to_name "$(ep_ip "$ep")")" "$ep" $row
    else
      printf "%-16s %-26s %s\n" "$(ip_to_name "$(ep_ip "$ep")")" "$ep" "DOWN / unreachable"
    fi
  done
}

haproxy_backends() {
  if [ -S /run/haproxy/admin.sock ]; then
    echo "show stat" | socat stdio /run/haproxy/admin.sock 2>/dev/null \
      | awk -F, '$1=="k8s-control-planes" && $2!="BACKEND" {printf "  %-16s %s\n",$2,$18}'
  else
    echo "  (run on the HA VM to see HAProxy backend status)"
  fi
}
