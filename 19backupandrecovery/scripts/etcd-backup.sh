#!/usr/bin/env bash
# Take an etcd snapshot from a kubeadm (or minikube) single-node cluster.
# etcd runs as a static pod; its certs live under /etc/kubernetes/pki/etcd.
# Run this on the control-plane VM (needs sudo).
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/etcd-backup}"
STAMP=$(date +%Y%m%d-%H%M%S)
SNAP="${BACKUP_DIR}/etcd-snapshot-${STAMP}.db"

mkdir -p "$BACKUP_DIR"

# Install etcdctl if it isn't on PATH (Debian/Ubuntu).
if ! command -v etcdctl >/dev/null 2>&1; then
  echo "==> etcdctl not found, installing etcd-client"
  sudo apt-get update -y && sudo apt-get install -y etcd-client
fi

echo "==> Saving snapshot to $SNAP"
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "$SNAP"

echo "==> Verifying snapshot"
sudo ETCDCTL_API=3 etcdctl snapshot status "$SNAP" --write-out=table

sudo chown "$(id -u):$(id -g)" "$SNAP"
echo
echo "==> Backup complete: $SNAP"
echo "    Copy it to cluster 2 with, e.g.:"
echo "    scp \"$SNAP\" user@CLUSTER2_IP:~/"
