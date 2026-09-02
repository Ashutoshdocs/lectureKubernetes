#!/usr/bin/env bash
# Dump the contents of a LIVE cluster's own etcd (read-only).
# Run on the control-plane VM. Useful to inspect what Kubernetes stores.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$PWD/etcd-output}"
mkdir -p "$OUT_DIR"

if ! command -v etcdctl >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y etcd-client
fi

E="sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

echo "==> Cluster / member health"
eval "$E endpoint status --write-out=table" | tee "$OUT_DIR/etcd-status.txt"

echo "==> All keys -> $OUT_DIR/etcd-keys-live.txt"
eval "$E get \"\" --prefix --keys-only" | sed '/^$/d' | sort > "$OUT_DIR/etcd-keys-live.txt"

echo "==> Inventory -> $OUT_DIR/etcd-inventory-live.txt"
awk -F/ '/^\/registry\// { print $3 }' "$OUT_DIR/etcd-keys-live.txt" \
  | sort | uniq -c | sort -rn > "$OUT_DIR/etcd-inventory-live.txt"

echo
echo "==> $(wc -l < "$OUT_DIR/etcd-keys-live.txt") keys. Top resource types:"
head -n 12 "$OUT_DIR/etcd-inventory-live.txt" | sed 's/^/    /'
