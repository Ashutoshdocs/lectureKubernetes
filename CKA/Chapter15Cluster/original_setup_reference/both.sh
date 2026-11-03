#!/bin/bash
set -e

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
apt update
apt install -y containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "=== Install Kubernetes components ==="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list

apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "=== Common setup completed ==="

