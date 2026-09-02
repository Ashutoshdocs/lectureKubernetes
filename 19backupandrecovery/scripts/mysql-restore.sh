#!/usr/bin/env bash
# Load a MySQL dump (from mysql-backup.sh) into cluster 2's MySQL.
# Run this AFTER the app is deployed on cluster 2 and MySQL is Ready.
# Usage: ./mysql-restore.sh arcade-db-XXXX.sql
set -euo pipefail

NS="${NS:-arcade}"
DUMP="${1:?Usage: $0 <dump.sql>}"

[ -f "$DUMP" ] || { echo "File not found: $DUMP" >&2; exit 1; }

echo "==> Waiting for MySQL to be ready in namespace '$NS'"
kubectl -n "$NS" rollout status deploy/mysql --timeout=180s

echo "==> Restoring $DUMP into MySQL"
kubectl -n "$NS" exec -i deploy/mysql -- \
  sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < "$DUMP"

echo "==> Done. Row count:"
kubectl -n "$NS" exec deploy/mysql -- \
  sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
    "SELECT CONCAT(COUNT(*),\" players restored\") FROM arcadedb.players;"'
