#!/bin/bash
# =====================================================================
# HAVM-GetClusterAccess.sh  -  run on the HA VM as your normal user (NOT sudo)
#     bash HAVM-GetClusterAccess.sh
#
# After ScriptForFirstMaster.sh, cp1 has ~/lb-bundle.tgz containing:
#   admin.conf (kubeconfig) + etcd CA + etcd client cert/key + etcd version
# This copies it over SSH (asks for the VM PASSWORD), installs it, and
# installs etcdctl matching the cluster's etcd version.
# =====================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

FIRST_CP="${CP_NODES%% *}"; FIRST_CP="${FIRST_CP%%:*}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "=== Copying bundle from ${FIRST_CP} (enter the VM password) ==="
scp -o StrictHostKeyChecking=accept-new "${ADMIN_USER}@${FIRST_CP}:lb-bundle.tgz" "$TMP/"
tar xzf "$TMP/lb-bundle.tgz" -C "$TMP"

echo "=== Installing kubeconfig for $(whoami) and root ==="
mkdir -p ~/.kube && cp "$TMP/admin.conf" ~/.kube/config && chmod 600 ~/.kube/config
sudo mkdir -p /root/.kube /etc/k8s-demo/etcd
sudo cp "$TMP/admin.conf" /root/.kube/config
sudo cp "$TMP/admin.conf" /etc/k8s-demo/admin.conf
sudo cp "$TMP/ca.crt" "$TMP/healthcheck-client.crt" "$TMP/healthcheck-client.key" /etc/k8s-demo/etcd/
sudo cp "$TMP/etcd-version" /etc/k8s-demo/etcd-version
sudo chmod 600 /etc/k8s-demo/admin.conf /etc/k8s-demo/etcd/*.key

ETCD_TAG=$(cat "$TMP/etcd-version")
echo "=== Installing etcdctl v${ETCD_TAG} ==="
if ! etcdctl version 2>/dev/null | grep -q "etcdctl version: ${ETCD_TAG}"; then
  curl -fsSL -o "$TMP/etcd.tgz" \
    "https://github.com/etcd-io/etcd/releases/download/v${ETCD_TAG}/etcd-v${ETCD_TAG}-linux-amd64.tar.gz"
  tar xzf "$TMP/etcd.tgz" -C "$TMP"
  sudo install -m 755 "$TMP/etcd-v${ETCD_TAG}-linux-amd64/etcdctl" "$TMP/etcd-v${ETCD_TAG}-linux-amd64/etcdutl" /usr/local/bin/
fi
etcdctl version | head -1

echo ""
echo "=== Test ==="
kubectl cluster-info
kubectl get nodes -o wide
echo ""
echo "You can now run everything from this HA VM:"
echo "  kubectl ...  |  sudo bash 01-show-leaders.sh  |  sudo bash 02-replication-demo.sh"
