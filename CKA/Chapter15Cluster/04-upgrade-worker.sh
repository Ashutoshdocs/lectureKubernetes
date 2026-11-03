#!/bin/bash
# =====================================================================
# 04-upgrade-worker.sh   (WORKER, root)
#   BEFORE (on master):  kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data
#   RUN    (on worker):  sudo NEW_VERSION=1.35 bash 04-upgrade-worker.sh
#   AFTER  (on master):  kubectl uncordon <worker>
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

NEW_VERSION="${NEW_VERSION:-1.35}"

echo "=== Step 1: switch apt repo to v${NEW_VERSION} ==="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${NEW_VERSION}/deb/Release.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${NEW_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update

PKG_VER=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${NEW_VERSION}\." | head -1)
echo "=== Target package: ${PKG_VER} ==="

echo "=== Step 2: upgrade kubeadm ==="
apt-mark unhold kubeadm
apt-get install -y kubeadm="${PKG_VER}"
apt-mark hold kubeadm

echo "=== Step 3: kubeadm upgrade node (updates local kubelet config) ==="
kubeadm upgrade node

echo "=== Step 4: upgrade kubelet + kubectl ==="
apt-mark unhold kubelet kubectl
apt-get install -y kubelet="${PKG_VER}" kubectl="${PKG_VER}"
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet

kubelet --version
echo "=== Worker upgraded. Now on MASTER: kubectl uncordon $(hostname) ==="
