#!/bin/bash
# ============================================================
# Run on k8s-control-plane (10.0.1.5) with sudo:
#   sudo bash scripts/01-init-control-plane.sh
#
# - kubeadm init
# - kubeconfig for azureuser and root
# - Calico CNI in VXLAN mode (works on Azure without extra routes)
# - prints the worker join command (also saved to /root/worker_join.sh)
# ============================================================
set -euo pipefail

CP_IP="10.0.1.5"
POD_CIDR="192.168.0.0/16"        # must NOT overlap the VNet 10.0.0.0/16
CALICO_VERSION="v3.31.7"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

echo "=== Checking node bootstrap finished ==="
cloud-init status --wait >/dev/null || true
tail -n 1 /var/log/lab-setup.log

echo "=== Initializing Kubernetes Control Plane ==="
kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}" | tee /root/kubeadm-init.log

echo "=== Setting kubeconfig ==="
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
USER_NAME="${SUDO_USER:-azureuser}"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown "$(id -u "$USER_NAME"):$(id -g "$USER_NAME")" "$USER_HOME/.kube/config"
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=== Installing Calico ${CALICO_VERSION} (VXLAN mode for Azure) ==="
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
  -o /root/calico.yaml
# Default pool: IPIP off, VXLAN on (Azure drops IP-in-IP / unknown pod routes)
sed -i '/name: CALICO_IPV4POOL_IPIP/{n;s/"Always"/"Never"/}' /root/calico.yaml
sed -i '/name: CALICO_IPV4POOL_VXLAN/{n;s/"Never"/"Always"/}' /root/calico.yaml
grep -A1 -E 'CALICO_IPV4POOL_(IPIP|VXLAN)$' /root/calico.yaml
kubectl apply -f /root/calico.yaml

echo "=== Waiting for Calico ==="
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s

echo "=== Generating worker join command ==="
kubeadm token create --print-join-command > /root/worker_join.sh
chmod +x /root/worker_join.sh

echo
echo "============================================================"
echo " Control plane ready. Run THIS with sudo on k8s-worker-1"
echo " and k8s-worker-2:"
echo "============================================================"
echo "sudo $(cat /root/worker_join.sh)"
echo "============================================================"
