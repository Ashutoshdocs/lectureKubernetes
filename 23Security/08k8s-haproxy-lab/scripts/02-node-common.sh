#!/usr/bin/env bash
###############################################################################
# 02-node-common.sh
#
# Run this on EVERY Kubernetes node:
#   cluster1-cp, cluster1-worker, cluster2-cp, cluster2-worker
# (Do NOT run on haproxy-vm or clusterwork.)
#
# It installs the container runtime (containerd) and the Kubernetes binaries
# (kubeadm, kubelet, kubectl), and applies the kernel settings kubeadm needs.
#
# Usage:  sudo bash 02-node-common.sh
###############################################################################
set -euo pipefail

# v1.33 = current LTS line. Change this ONE variable to use another minor.
K8S_MINOR="v1.33"

echo ">> [1/6] Disable swap (kubelet requirement)"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo ">> [2/6] Load kernel modules"
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">> [3/6] Sysctl for bridged traffic + forwarding"
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo ">> [4/6] Install containerd"
apt-get update -y
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
# Use the systemd cgroup driver (must match kubelet) -- classic gotcha
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo ">> [5/6] Add Kubernetes ($K8S_MINOR) apt repo"
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

echo ">> [6/6] Install kubelet, kubeadm, kubectl (and pin them)"
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo
echo ">> DONE. Versions:"
kubeadm version -o short
kubectl version --client -o yaml | grep gitVersion || true
