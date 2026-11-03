#!/bin/bash
# =====================================================================
# 03-upgrade-master.sh   (MASTER, root)
#     sudo NEW_VERSION=1.35 bash 03-upgrade-master.sh
#
# Upgrades control plane: kubeadm -> kube-apiserver, controller-manager,
# scheduler, etcd, kube-proxy, CoreDNS -> then kubelet + kubectl.
# kubeadm can only upgrade ONE minor version at a time (1.34 -> 1.35).
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

NEW_VERSION="${NEW_VERSION:-1.35}"     # <-- NEW version (minor only)
export KUBECONFIG=/etc/kubernetes/admin.conf
NODE=$(hostname)

# --- Safety check: kubeadm upgrades only ONE minor version at a time
CUR_MINOR=$(kubectl version -o json | grep -A5 serverVersion | grep -oP '"minor": "\K[0-9]+')
NEW_MINOR=${NEW_VERSION#*.}
if [ $((NEW_MINOR - CUR_MINOR)) -ne 1 ]; then
  echo "ERROR: cluster is on 1.${CUR_MINOR}, NEW_VERSION=${NEW_VERSION}."
  echo "kubeadm can only upgrade one minor at a time. Use NEW_VERSION=1.$((CUR_MINOR + 1))"
  exit 1
fi

echo "=== BEFORE upgrade ==="
kubectl get nodes -o wide
kubeadm version -o short

echo "=== Step 1: switch apt repo to v${NEW_VERSION} ==="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${NEW_VERSION}/deb/Release.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${NEW_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update

# latest patch of the new minor, e.g. 1.35.2-1.1
PKG_VER=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${NEW_VERSION}\." | head -1)
TARGET="v${PKG_VER%%-*}"
echo "=== Target version: ${TARGET} (package ${PKG_VER}) ==="

echo "=== Step 2: upgrade kubeadm ==="
apt-mark unhold kubeadm
apt-get install -y --allow-downgrades kubeadm="${PKG_VER}"
apt-mark hold kubeadm
kubeadm version -o short

echo "=== Step 3: kubeadm upgrade plan ==="
kubeadm upgrade plan

echo "=== Step 4: kubeadm upgrade apply ${TARGET} (control plane components + etcd + addons) ==="
kubeadm upgrade apply "${TARGET}" -y

echo "=== Step 5: drain master ==="
kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data

echo "=== Step 6: upgrade kubelet + kubectl ==="
apt-mark unhold kubelet kubectl
apt-get install -y --allow-downgrades kubelet="${PKG_VER}" kubectl="${PKG_VER}"
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet

echo "=== Step 7: uncordon master ==="
sleep 20
kubectl uncordon "${NODE}"

echo "=== AFTER master upgrade ==="
kubectl get nodes -o wide
kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
echo ""
echo "Next: drain worker ->  kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data"
echo "      then on WORKER: sudo NEW_VERSION=${NEW_VERSION} bash 04-upgrade-worker.sh"
