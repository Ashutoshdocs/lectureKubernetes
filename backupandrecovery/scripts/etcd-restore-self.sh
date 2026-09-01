#!/usr/bin/env bash
# Restore an etcd snapshot back onto THIS SAME kubeadm control-plane node,
# to recover Kubernetes objects that were deleted/lost after the snapshot.
#
# Same node = same certs, so no PKI copying is needed (unlike a cross-cluster
# clone). The script backs up everything it touches and can be rolled back.
#
# Usage: sudo ./etcd-restore-self.sh /path/to/etcd-snapshot-XXXX.db
set -euo pipefail

SNAP="${1:?Usage: sudo $0 <snapshot.db>}"
[ -f "$SNAP" ] || { echo "Snapshot not found: $SNAP" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

ETCD_VER="${ETCD_VER:-v3.5.16}"
MANIFESTS=/etc/kubernetes/manifests
DATA_DIR=/var/lib/etcd
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=~/etcd-restore-backup-$STAMP
HOLD=/etc/kubernetes/manifests-stopped-$STAMP
WORK="$(mktemp -d /tmp/etcd-restore.XXXXXX)"

ETCD_MANIFEST="$MANIFESTS/etcd.yaml"
[ -f "$ETCD_MANIFEST" ] || { echo "No $ETCD_MANIFEST — is this a kubeadm control plane?" >&2; exit 1; }

# Read this node's etcd identity from its own manifest (before we move it).
NAME=$(grep -oP -- '--name=\K[^ ]+'                        "$ETCD_MANIFEST" | head -1)
PEER=$(grep -oP -- '--initial-advertise-peer-urls=\K[^ ]+' "$ETCD_MANIFEST" | head -1)
CLUSTER=$(grep -oP -- '--initial-cluster=\K[^ ]+'          "$ETCD_MANIFEST" | head -1)
[ -n "$NAME" ] && [ -n "$PEER" ] && [ -n "$CLUSTER" ] || { echo "Could not parse etcd flags from $ETCD_MANIFEST" >&2; exit 1; }

echo "############################################################"
echo "#  etcd restore on THIS node                               #"
echo "#  snapshot : $SNAP"
echo "#  identity : name=$NAME"
echo "#             cluster=$CLUSTER"
echo "#  backups  : $BACKUP"
echo "#  The API server will be briefly down during the restore.  #"
echo "############################################################"
read -r -p "Type YES to continue: " ans
[ "$ans" = "YES" ] || { echo "Aborted."; exit 1; }

# --- get etcdutl (ships in the etcd release tarball) ---
if command -v etcdutl >/dev/null 2>&1; then
  ETCDUTL=$(command -v etcdutl)
else
  echo "==> Downloading etcd $ETCD_VER (for etcdutl)"
  TB="etcd-${ETCD_VER}-linux-amd64.tar.gz"
  curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/${TB}" -o "$WORK/$TB"
  tar xzf "$WORK/$TB" -C "$WORK" --strip-components=1
  ETCDUTL="$WORK/etcdutl"
fi

mkdir -p "$BACKUP"
cp -a "$ETCD_MANIFEST" "$BACKUP/etcd.yaml.bak"
echo "==> Backed up etcd.yaml -> $BACKUP/etcd.yaml.bak"

# --- stop the control plane by parking the static pod manifests ---
echo "==> Stopping control-plane static pods (apiserver, etcd, ...)"
mkdir -p "$HOLD"
mv "$MANIFESTS"/*.yaml "$HOLD"/
sleep 15    # let kubelet tear the containers down

# --- move current (bad) data aside, restore snapshot into a fresh data dir ---
if [ -d "$DATA_DIR" ]; then
  mv "$DATA_DIR" "$BACKUP/etcd-data.old"
  echo "==> Moved current $DATA_DIR -> $BACKUP/etcd-data.old"
fi

echo "==> Restoring snapshot into $DATA_DIR"
"$ETCDUTL" snapshot restore "$SNAP" \
  --name "$NAME" \
  --initial-cluster "$CLUSTER" \
  --initial-advertise-peer-urls "$PEER" \
  --data-dir "$DATA_DIR"

# --- bring the control plane back ---
echo "==> Restarting control-plane static pods"
mv "$HOLD"/*.yaml "$MANIFESTS"/
rmdir "$HOLD" 2>/dev/null || true
rm -rf "$WORK"

echo "==> Waiting for the API server to answer (~1-2 min)..."
for i in $(seq 1 40); do
  if kubectl get ns >/dev/null 2>&1; then
    echo "==> API server is back."
    break
  fi
  sleep 3
done

echo
echo "======================================================"
echo "  Restore complete. Verify what came back:"
echo "     kubectl get ns"
echo "     kubectl -n arcade get all"
echo
echo "  Backups (for rollback) in: $BACKUP"
echo "    - etcd.yaml.bak     the manifest as it was"
echo "    - etcd-data.old     the pre-restore etcd data"
echo "======================================================"
