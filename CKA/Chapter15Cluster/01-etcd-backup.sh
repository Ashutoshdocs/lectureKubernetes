#!/bin/bash
# =====================================================================
# 01-etcd-backup.sh   (MASTER, root)   sudo bash 01-etcd-backup.sh
# Installs etcdctl/etcdutl matching the cluster's etcd version, then
# takes a snapshot of etcd BEFORE we create the demo deployments.
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

BACKUP_DIR="${BACKUP_DIR:-/opt/etcd-backup}"
SNAPSHOT="${BACKUP_DIR}/etcd-snapshot-before-upgrade.db"
export KUBECONFIG=/etc/kubernetes/admin.conf

# --- detect etcd version from the static pod manifest (e.g. 3.6.4-0 -> v3.6.4)
ETCD_TAG=$(grep -oP 'image:.*etcd:\K[0-9.]+' /etc/kubernetes/manifests/etcd.yaml)
ETCD_VER="v${ETCD_TAG}"
echo "=== Cluster etcd version: ${ETCD_VER} ==="

if ! command -v etcdutl >/dev/null || ! etcdctl version 2>/dev/null | grep -q "${ETCD_TAG}"; then
  echo "=== Installing etcdctl + etcdutl ${ETCD_VER} ==="
  cd /tmp
  curl -fsSL -o etcd.tgz \
    https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
  tar xzf etcd.tgz
  install -m 755 etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
  install -m 755 etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
  rm -rf etcd.tgz etcd-${ETCD_VER}-linux-amd64
fi
etcdctl version

mkdir -p "${BACKUP_DIR}"

echo "=== Record cluster state at backup time ==="
kubectl get nodes -o wide            | tee "${BACKUP_DIR}/nodes-before.txt"
kubectl get deploy -A                | tee "${BACKUP_DIR}/deployments-before.txt"

echo "=== Taking etcd snapshot ==="
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "${SNAPSHOT}"

echo "=== Verify snapshot ==="
etcdutl snapshot status "${SNAPSHOT}" -w table

# Extra safety: keep a copy of certs + manifests (needed in real DR)
cp -r /etc/kubernetes/pki "${BACKUP_DIR}/pki-backup"
cp -r /etc/kubernetes/manifests "${BACKUP_DIR}/manifests-backup"

echo "=== Backup saved: ${SNAPSHOT} ==="
