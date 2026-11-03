#!/bin/bash
# =====================================================================
# ScriptForHAVM.sh   -  run on the HA VM (vm-k8s-lb) as root, FIRST
#     sudo bash ScriptForHAVM.sh
#
# Turns vm-k8s-lb into:
#   1. the cluster's API load balancer:
#        k8s-api:6443  ->  HAProxy  ->  cp1/cp2/cp3 :6443  (health-checked)
#        stats page:     http://<lb-private-ip>:8404/stats   (curl from VNet)
#   2. the ADMIN box: kubectl, etcdctl, jq, Azure CLI
#      (cluster credentials come later via HAVM-GetClusterAccess.sh)
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

INSTALL_AZ_CLI="${INSTALL_AZ_CLI:-yes}"

echo "=== Packages ==="
apt-get update -q
apt-get install -y -q haproxy jq socat curl gpg ca-certificates apt-transport-https

echo "=== /etc/hosts ==="
sed -i '/# k8s-ha-demo/d' /etc/hosts
echo "${LB_IP} ${API_ENDPOINT_NAME} ${LB_NAME}   # k8s-ha-demo" >> /etc/hosts
for n in ${CP_NODES} ${WORKER_NODES} ${NEW_NODE_NAME}:${NEW_NODE_IP}; do
  echo "${n##*:} ${n%%:*}   # k8s-ha-demo" >> /etc/hosts
done

echo "=== HAProxy: ${LB_IP}:${API_ENDPOINT_PORT} -> control planes ==="
{
cat <<EOF
global
    log /dev/log local0
    maxconn 4000
    stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend k8s-api
    bind *:${API_ENDPOINT_PORT}
    default_backend k8s-control-planes

backend k8s-control-planes
    balance roundrobin
    option tcp-check
    default-server inter 3s fall 2 rise 2
EOF
for n in ${CP_NODES}; do
  echo "    server ${n%%:*} ${n##*:}:6443 check"
done
cat <<EOF

listen stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s
EOF
} > /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy

echo "=== kubectl v${K8S_VERSION} ==="
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubectl
apt-mark hold kubectl

if [ "${INSTALL_AZ_CLI}" = "yes" ]; then
  echo "=== Azure CLI (for 04-vm-power.sh / 05-add-new-node.sh) ==="
  command -v az >/dev/null || curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi

echo ""
echo "================================================================="
echo " HA VM ready."
echo "   HAProxy  : ${API_ENDPOINT_NAME} (${LB_IP}):${API_ENDPOINT_PORT}  -> $(echo ${CP_NODES} | sed 's/:[0-9.]*//g')"
echo "   Backends show DOWN until the control planes are up - that's expected."
echo "   Check    : echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18"
echo ""
echo " Next: run ScriptForAllNodes.sh on the 6 cluster nodes,"
echo "       then ScriptForFirstMaster.sh on ${CP_NODES%%:*}."
echo "================================================================="
