#!/usr/bin/env bash
###############################################################################
# 04-init-cluster.sh   -- run on a control-plane VM (cluster1-cp OR cluster2-cp)
#
# Initializes a single-control-plane Kubernetes cluster with kubeadm and
# installs the Flannel CNI. The critical flag is --apiserver-cert-extra-sans:
# it puts the HAProxy IP into the API server's TLS certificate, so kubectl
# reaching the API *through HAProxy* passes TLS verification.
#
# Cluster-internal traffic (kubelet, worker join) still goes DIRECT to this
# node's own IP. Only the two human users go through HAProxy.
#
# Usage (on cluster1-cp):
#   sudo HAPROXY_IP=10.0.1.4 bash 04-init-cluster.sh
# Usage (on cluster2-cp):
#   sudo HAPROXY_IP=10.0.1.4 bash 04-init-cluster.sh
###############################################################################
set -euo pipefail

: "${HAPROXY_IP:?set HAPROXY_IP to the haproxy-vm private IP}"

echo ">> kubeadm init (this pulls images, ~2-4 min)"
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-cert-extra-sans="${HAPROXY_IP}" \
  --ignore-preflight-errors=NumCPU

echo ">> Set up kubectl for the azureuser on THIS control-plane node"
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
# If you sudo'd, also fix the real user's config:
if [ -n "${SUDO_USER:-}" ]; then
  install -d -o "$SUDO_USER" -g "$SUDO_USER" "/home/$SUDO_USER/.kube"
  cp -f /etc/kubernetes/admin.conf "/home/$SUDO_USER/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "/home/$SUDO_USER/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

echo ">> Install Flannel CNI"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo
echo ">> Worker join command (copy this, run on the matching worker):"
echo "-----------------------------------------------------------------"
kubeadm token create --print-join-command
echo "-----------------------------------------------------------------"
echo
echo ">> Watch nodes become Ready:  kubectl get nodes -w"
