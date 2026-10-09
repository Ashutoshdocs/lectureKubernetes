#!/usr/bin/env bash
# Breaks the CURRENT primary for real:
#   1. hides its control file (global/pg_control) - Postgres cannot start without it
#   2. sends SIGQUIT to PID 1 (postgres) = immediate shutdown / crash
# Kubernetes restarts the container, Postgres fails to start -> CrashLoopBackOff.
# A restart does NOT heal it; that is the point.
set -euo pipefail
NS=${NS:-pg-demo}
PRIMARY=$(kubectl -n "$NS" get cm pg-cluster -o jsonpath='{.data.PRIMARY_INSTANCE}')
POD="${PRIMARY}-0"

echo ">> Breaking current primary: $POD"
kubectl -n "$NS" exec "$POD" -- bash -c \
  'mv "$PGDATA/global/pg_control" "$PGDATA/global/pg_control.broken" && kill -QUIT 1' || true

echo ">> Watch it crash-loop (Ctrl+C to stop):"
kubectl -n "$NS" get pod "$POD" -w
