#!/bin/bash
# =====================================================================
# ScriptForBothNode.sh
# Run on BOTH nodes (master + worker) as root:   sudo bash ScriptForBothNode.sh
#
# Installs the OLDER Kubernetes version so we can upgrade it later.
# Change the version like:  sudo K8S_VERSION=1.33 bash ScriptForBothNode.sh
# =====================================================================
set -e

K8S_VERSION="${K8S_VERSION:-1.34}"     # <-- OLD version (minor only, e.g. 1.34)

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

echo "=== Installing Kubernetes v${K8S_VERSION} prerequisites ==="

echo "=== Disable Swap ==="
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "=== Load Kernel Modules ==="
cat <<EOF | tee /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF
modprobe br_netfilter
modprobe overlay

echo "=== Set sysctl params ==="
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system

echo "=== Install containerd ==="
apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# align sandbox (pause) image with what kubeadm expects (removes a preflight warning)
sed -i 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.10"#' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "=== Add Kubernetes v${K8S_VERSION} apt repo ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo "=== Installed versions ==="
kubeadm version -o short
kubelet --version
kubectl version --client

echo "=== Common setup completed (v${K8S_VERSION}) ==="
echo "Master: run ScriptFormaster.sh | Worker: wait for worker_join.sh from master"
