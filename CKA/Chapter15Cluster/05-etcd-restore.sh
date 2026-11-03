#!/bin/bash
# =====================================================================
# 05-etcd-restore.sh   (MASTER, root)   sudo bash 05-etcd-restore.sh
#
# Restores the snapshot taken in step 01 onto the UPGRADED cluster.
# Expected result: the 3 deployments in 'upgrade-demo' are GONE
# (they were created after the snapshot).
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

BACKUP_DIR="${BACKUP_DIR:-/opt/etcd-backup}"
SNAPSHOT="${BACKUP_DIR}/etcd-snapshot-before-upgrade.db"
MANIFESTS=/etc/kubernetes/manifests
PARKED=/etc/kubernetes/manifests-parked
export KUBECONFIG=/etc/kubernetes/admin.conf

[ -f "${SNAPSHOT}" ] || { echo "Snapshot not found: ${SNAPSHOT}"; exit 1; }

echo "=== State BEFORE restore ==="
kubectl get deploy -A || true

echo "=== Step 1: stop control plane (move static pod manifests out) ==="
mkdir -p "${PARKED}"
mv ${MANIFESTS}/*.yaml "${PARKED}/"
echo "Waiting for apiserver/etcd containers to stop..."
for i in $(seq 1 30); do
  crictl ps 2>/dev/null | grep -qE 'etcd|kube-apiserver' || break
  sleep 3
done
crictl ps | grep -E 'etcd|kube-apiserver' || echo "control plane stopped"

echo "=== Step 2: move current etcd data aside ==="
mv /var/lib/etcd "/var/lib/etcd.old-$(date +%s)"

echo "=== Step 3: restore snapshot into /var/lib/etcd ==="
# use same member name / peer URL as the etcd static pod manifest
ETCD_NAME=$(grep -oP -- '--name=\K\S+' "${PARKED}/etcd.yaml")
PEER_URL=$(grep -oP -- '--initial-advertise-peer-urls=\K\S+' "${PARKED}/etcd.yaml")
etcdutl snapshot restore "${SNAPSHOT}" \
  --data-dir /var/lib/etcd \
  --name "${ETCD_NAME}" \
  --initial-cluster "${ETCD_NAME}=${PEER_URL}" \
  --initial-advertise-peer-urls "${PEER_URL}"

echo "=== Step 4: start control plane again ==="
mv ${PARKED}/*.yaml ${MANIFESTS}/
systemctl restart kubelet

echo "Waiting for API server..."
until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done

echo "=== Step 5: re-sync cluster config to the upgraded version ==="
# The snapshot was taken on the OLD version, so objects like the
# kubeadm-config ConfigMap, kube-proxy and CoreDNS went back to old values.
# Re-applying the (same) new version fixes that; binaries are untouched.
TARGET=$(kubeadm version -o short)
kubeadm upgrade apply "${TARGET}" -y

echo "=== State AFTER restore ==="
kubectl get nodes -o wide
kubectl get deploy -A
echo ""
echo "Expected: namespace 'upgrade-demo' and its 3 deployments are gone,"
echo "nodes still show the NEW version."
