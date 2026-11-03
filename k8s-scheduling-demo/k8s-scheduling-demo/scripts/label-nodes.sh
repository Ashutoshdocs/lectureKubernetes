#!/usr/bin/env bash
# Applies the base labels used by every demo. Safe to re-run (uses --overwrite).
set -euo pipefail

echo ">> Zone labels (well-known key topology.kubernetes.io/zone)"
for n in worker-a1 worker-a2 worker-a3; do
  kubectl label node "$n" topology.kubernetes.io/zone=zone-a --overwrite
done
for n in worker-b1 worker-b2; do
  kubectl label node "$n" topology.kubernetes.io/zone=zone-b --overwrite
done

echo ">> Worker role label (cosmetic - fills the ROLES column)"
for n in worker-a1 worker-a2 worker-a3 worker-b1 worker-b2; do
  kubectl label node "$n" node-role.kubernetes.io/worker= --overwrite
done

echo ">> Disk type labels (used by preferred node affinity demo)"
kubectl label node worker-a1 disktype=ssd --overwrite
kubectl label node worker-b1 disktype=ssd --overwrite
for n in worker-a2 worker-a3 worker-b2; do
  kubectl label node "$n" disktype=hdd --overwrite
done

echo
kubectl get nodes -L topology.kubernetes.io/zone,disktype,env
