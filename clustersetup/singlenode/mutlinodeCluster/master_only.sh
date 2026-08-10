#!/bin/bash
set -e

POD_CIDR="192.168.0.0/16"

echo "=== Writing kubeadm config ==="
cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
networking:
  podSubnet: "${POD_CIDR}"
EOF

echo "=== Initializing Kubernetes Control Plane ==="
kubeadm init --config /root/kubeadm-config.yaml | tee /root/kubeadm-init.log

echo "=== Setting kubeconfig ==="
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "=== Installing Calico CNI ==="
curl -L https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml \
    -o /root/calico.yaml
kubectl apply -f /root/calico.yaml

echo "=== WAIT for Calico CRDs to be ready ==="
sleep 20

echo "=== Deleting default Calico IPPools if any ==="
kubectl delete ippools.crd.projectcalico.org default-ipv4-ippool --ignore-not-found=true
kubectl delete ippool default-ipv4-ippool --ignore-not-found=true

echo "=== Creating custom Azure-safe VXLAN IPPool ==="
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: azure-ippool
spec:
  cidr: ${POD_CIDR}
  vxlanMode: Always
  ipipMode: Never
  natOutgoing: true
  disabled: false
EOF

echo "=== Restart Calico nodes ==="
kubectl rollout restart daemonset/calico-node -n kube-system

echo "=== Generating worker join script ==="
kubeadm token create --print-join-command > /root/worker_join.sh
chmod +x /root/worker_join.sh
echo "Run /root/worker_join.sh on every worker node."

echo "=== Master setup complete ==="

