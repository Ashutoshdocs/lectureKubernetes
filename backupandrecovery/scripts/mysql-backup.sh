#!/usr/bin/env bash
# Dump the RPS game data (the players table) from cluster 1's MySQL.
# etcd snapshots do NOT contain this data — it lives in MySQL's volume.
# Run on cluster 1.
set -euo pipefail

NS="${NS:-arcade}"
OUT="${1:-arcade-db-$(date +%Y%m%d-%H%M%S).sql}"

echo "==> Dumping database from namespace '$NS' -> $OUT"
kubectl -n "$NS" exec deploy/mysql -- \
  sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --databases arcadedb' > "$OUT"

BYTES=$(wc -c < "$OUT")
echo "==> Wrote $OUT ($BYTES bytes)"
echo "    Copy it to cluster 2 with:"
echo "    scp \"$OUT\" user@CLUSTER2_IP:~/"
