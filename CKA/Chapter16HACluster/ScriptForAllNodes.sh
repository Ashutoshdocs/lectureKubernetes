#!/bin/bash
# =====================================================================
# ScriptForAllNodes.sh   -  run on ALL 6 cluster nodes (3 CP + 3 workers) as root
#                           (NOT on the HA VM - it uses ScriptForHAVM.sh)
#     sudo bash ScriptForAllNodes.sh
#
# - swap off, kernel modules, sysctl, containerd
# - kubeadm / kubelet / kubectl (version from cluster.env)
# - /etc/hosts entries for every node + k8s-api -> HA VM (HAProxy)
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# cluster.env may already be inlined (05-add-new-node.sh does that)
if [ -z "${CP_NODES}" ]; then source "${SCRIPT_DIR}/cluster.env"; fi

echo "=== [$(hostname)] Installing Kubernetes v${K8S_VERSION} prerequisites ==="

echo "=== Disable swap ==="
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "=== Kernel modules + sysctl ==="
cat <<EOF > /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF
modprobe br_netfilter
modprobe overlay
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system >/dev/null

echo "=== containerd + tools ==="
apt-get update -q
apt-get install -y -q containerd apt-transport-https ca-certificates curl gpg jq
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.10"#' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
echo "runtime-endpoint: unix:///run/containerd/containerd.sock" > /etc/crictl.yaml

echo "=== /etc/hosts ==="
sed -i '/# k8s-ha-demo/d' /etc/hosts
echo "${LB_IP} ${API_ENDPOINT_NAME} ${LB_NAME}   # k8s-ha-demo" >> /etc/hosts
for n in ${CP_NODES} ${WORKER_NODES} ${NEW_NODE_NAME}:${NEW_NODE_IP}; do
  echo "${n##*:} ${n%%:*}   # k8s-ha-demo" >> /etc/hosts
done

echo "=== Kubernetes v${K8S_VERSION} apt repo + packages ==="
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo ""
echo "=== [$(hostname)] done: $(kubeadm version -o short) ==="
echo "First control plane -> sudo bash ScriptForFirstMaster.sh"
echo "Others              -> run the join file generated on the first control plane"
