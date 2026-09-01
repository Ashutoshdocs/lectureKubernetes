#!/usr/bin/env bash
# PATH B (DESTRUCTIVE): restore a snapshot into THIS node's etcd, so this
# cluster takes on the state from the snapshot. Intended for a throwaway
# cluster 2 as a disaster-recovery drill. Backs up everything it touches.
#
# Prereq: you have already copied cluster 1's PKI and regenerated cluster 2's
# IP-bound certs (see README section 7.1). This script does the etcd part only.
#
# Usage: ./etcd-clone-into.sh /path/to/etcd-snapshot-XXXX.db
set -euo pipefail

SNAP="${1:?Usage: $0 <snapshot.db>}"
[ -f "$SNAP" ] || { echo "Snapshot not found: $SNAP" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

ETCD_VER="${ETCD_VER:-v3.5.16}"
MANIFESTS=/etc/kubernetes/manifests
DATA_DIR=/var/lib/etcd
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=~/etcd-clone-backup-$STAMP
HOLD=/etc/kubernetes/manifests-disabled-$STAMP
WORK="$(mktemp -d /tmp/etcd-clone.XXXXXX)"

echo "############################################################"
echo "#  DESTRUCTIVE: this replaces this node's etcd state.       #"
echo "#  Backups go to: $BACKUP"
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

# --- read this node's etcd identity from its current manifest ---
ETCD_MANIFEST="$MANIFESTS/etcd.yaml"
[ -f "$ETCD_MANIFEST" ] || { echo "No $ETCD_MANIFEST — is this a kubeadm control plane?" >&2; exit 1; }
NAME=$(grep -oP -- '--name=\K[^ ]+'                        "$ETCD_MANIFEST" | head -1)
PEER=$(grep -oP -- '--initial-advertise-peer-urls=\K[^ ]+' "$ETCD_MANIFEST" | head -1)
CLUSTER=$(grep -oP -- '--initial-cluster=\K[^ ]+'          "$ETCD_MANIFEST" | head -1)
echo "==> etcd identity: name=$NAME peer=$PEER cluster=$CLUSTER"
[ -n "$NAME" ] && [ -n "$PEER" ] && [ -n "$CLUSTER" ] || { echo "Could not parse etcd flags." >&2; exit 1; }

# --- back up manifest + current data ---
mkdir -p "$BACKUP"
cp -a "$ETCD_MANIFEST" "$BACKUP/etcd.yaml.bak"
echo "==> Backed up etcd.yaml -> $BACKUP/etcd.yaml.bak"

# --- stop the control plane by parking the static pod manifests ---
echo "==> Stopping control-plane static pods"
mkdir -p "$HOLD"
mv "$MANIFESTS"/*.yaml "$HOLD"/
# give kubelet a moment to tear the containers down
sleep 15

# --- move old data aside, restore snapshot into a fresh data dir ---
if [ -d "$DATA_DIR" ]; then
  mv "$DATA_DIR" "$BACKUP/etcd-data.old"
  echo "==> Moved old $DATA_DIR -> $BACKUP/etcd-data.old"
fi

echo "==> Restoring snapshot into $DATA_DIR"
"$ETCDUTL" snapshot restore "$SNAP" \
  --name "$NAME" \
  --initial-cluster "$CLUSTER" \
  --initial-advertise-peer-urls "$PEER" \
  --data-dir "$DATA_DIR"

# --- bring the control plane back ---
echo "==> Restoring static pod manifests"
mv "$HOLD"/*.yaml "$MANIFESTS"/
rmdir "$HOLD" 2>/dev/null || true
rm -rf "$WORK"

echo
echo "==> Waiting for the control plane to come back (~1-2 min)..."
for i in $(seq 1 40); do
  if kubectl get ns >/dev/null 2>&1; then
    echo "==> API server is answering."
    break
  fi
  sleep 3
done

echo
echo "======================================================"
echo "  Done. Verify:"
echo "     kubectl get ns"
echo "     kubectl -n arcade get pods"
echo
echo "  Backups kept in: $BACKUP"
echo "  To roll back: restore etcd.yaml.bak and etcd-data.old, then"
echo "  restart kubelet."
echo
echo "  Remember: this did NOT bring MySQL data. Run:"
echo "     ./scripts/mysql-restore.sh <your-dump>.sql"
echo "======================================================"
