#!/bin/bash
set -e

echo "========== STEP 1: Update packages =========="
apt update
apt install -y \
apt-transport-https \
ca-certificates \
curl \
gnupg \
lsb-release \
software-properties-common

echo "========== STEP 2: Disable Swap =========="
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "========== STEP 3: Enable Kernel Modules =========="
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "========== STEP 4: Configure Sysctl =========="
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system

echo "========== STEP 5: Install Docker Repository =========="
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
> /etc/apt/sources.list.d/docker.list

apt update

echo "========== STEP 6: Install Containerd =========="
apt install -y containerd.io

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
/etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "========== STEP 7: Install Kubernetes =========="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
| gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo \
"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
> /etc/apt/sources.list.d/kubernetes.list

apt update

apt install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "========== STEP 8: Initialize Cluster =========="

kubeadm init \
--pod-network-cidr=10.244.0.0/16

echo "========== STEP 9: Configure Kubectl =========="

mkdir -p $HOME/.kube

cp /etc/kubernetes/admin.conf $HOME/.kube/config

chown $(id -u):$(id -g) $HOME/.kube/config

echo "========== Waiting for API Server =========="

until kubectl get nodes >/dev/null 2>&1
do
    sleep 5
done

echo "========== STEP 10: Install Flannel =========="

kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.0/kube-flannel.yml

echo "========== Waiting for Flannel =========="

sleep 20

echo "========== STEP 11: Remove Control Plane Taint =========="

kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "========== STEP 12: Cluster Status =========="

kubectl get nodes

kubectl get pods -A
