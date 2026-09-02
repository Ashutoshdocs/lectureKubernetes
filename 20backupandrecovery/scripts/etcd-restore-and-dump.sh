#!/usr/bin/env bash
# Take a snapshot that was made on CLUSTER 1 and "dump" it on CLUSTER 2,
# WITHOUT touching cluster 2's real etcd.
#
# It restores the snapshot into a throwaway data dir, starts a temporary
# standalone etcd against it on non-standard ports, then exports every key
# and value.
#
# Usage:  ./etcd-restore-and-dump.sh /path/to/etcd-snapshot-XXXX.db
set -euo pipefail

SNAP="${1:?Usage: $0 <snapshot.db>}"
ETCD_VER="${ETCD_VER:-v3.5.16}"
WORK="$(mktemp -d /tmp/etcd-dump.XXXXXX)"
RESTORE_DIR="$WORK/data"
OUT_DIR="${OUT_DIR:-$PWD/etcd-output}"
CLIENT_URL="http://127.0.0.1:12379"
PEER_URL="http://127.0.0.1:12380"

mkdir -p "$OUT_DIR"

# ---- 1. make sure etcd + etcdctl exist (download static binaries if not) ----
BIN_DIR="$WORK/bin"
mkdir -p "$BIN_DIR"
if command -v etcd >/dev/null 2>&1 && command -v etcdctl >/dev/null 2>&1; then
  ETCD=$(command -v etcd); ETCDCTL=$(command -v etcdctl)
else
  echo "==> Downloading etcd $ETCD_VER static binaries"
  TARBALL="etcd-${ETCD_VER}-linux-amd64.tar.gz"
  URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/${TARBALL}"
  curl -fsSL "$URL" -o "$WORK/$TARBALL"
  tar xzf "$WORK/$TARBALL" -C "$BIN_DIR" --strip-components=1
  ETCD="$BIN_DIR/etcd"; ETCDCTL="$BIN_DIR/etcdctl"
fi

# ---- 2. restore the snapshot into a fresh data dir ----
echo "==> Restoring snapshot into $RESTORE_DIR"
ETCDCTL_API=3 "$ETCDCTL" snapshot restore "$SNAP" \
  --data-dir "$RESTORE_DIR" \
  --name dump-node \
  --initial-cluster dump-node="$PEER_URL" \
  --initial-advertise-peer-urls "$PEER_URL"

# ---- 3. start a temporary etcd against the restored data ----
echo "==> Starting temporary etcd"
"$ETCD" \
  --name dump-node \
  --data-dir "$RESTORE_DIR" \
  --listen-client-urls "$CLIENT_URL" \
  --advertise-client-urls "$CLIENT_URL" \
  --listen-peer-urls "$PEER_URL" \
  --initial-cluster dump-node="$PEER_URL" \
  --initial-advertise-peer-urls "$PEER_URL" \
  > "$WORK/etcd.log" 2>&1 &
ETCD_PID=$!
cleanup() { kill "$ETCD_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# wait for it to answer
for i in $(seq 1 20); do
  if ETCDCTL_API=3 "$ETCDCTL" --endpoints="$CLIENT_URL" endpoint health >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# ---- 4. dump ----
echo "==> Dumping all keys       -> $OUT_DIR/etcd-keys.txt"
ETCDCTL_API=3 "$ETCDCTL" --endpoints="$CLIENT_URL" get "" --prefix --keys-only \
  | sed '/^$/d' | sort > "$OUT_DIR/etcd-keys.txt"

echo "==> Dumping keys + values  -> $OUT_DIR/etcd-full.json"
ETCDCTL_API=3 "$ETCDCTL" --endpoints="$CLIENT_URL" get "" --prefix -w json \
  > "$OUT_DIR/etcd-full.json"

echo "==> Building resource inventory -> $OUT_DIR/etcd-inventory.txt"
awk -F/ '/^\/registry\// { print $3 }' "$OUT_DIR/etcd-keys.txt" \
  | sort | uniq -c | sort -rn > "$OUT_DIR/etcd-inventory.txt"

TOTAL=$(wc -l < "$OUT_DIR/etcd-keys.txt")
echo
echo "======================================================"
echo "  Dumped $TOTAL keys from the snapshot."
echo "  Files in $OUT_DIR:"
echo "    - etcd-keys.txt       every key (human readable)"
echo "    - etcd-full.json      keys + values (values are base64)"
echo "    - etcd-inventory.txt  count of objects per resource type"
echo
echo "  Top resource types stored in etcd:"
head -n 12 "$OUT_DIR/etcd-inventory.txt" | sed 's/^/    /'
echo "======================================================"
echo
echo "  Tip: values are Kubernetes protobuf. To decode them to YAML, use"
echo "       'auger' (github.com/etcd-io/auger), e.g.:"
echo "       ETCDCTL_API=3 $ETCDCTL --endpoints=$CLIENT_URL \\"
echo "         get /registry/pods/arcade/ --prefix -w fields ..."
