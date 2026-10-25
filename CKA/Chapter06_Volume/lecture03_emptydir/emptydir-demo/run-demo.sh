#!/usr/bin/env bash
# Deploys disk vs memory emptyDir pods, benchmarks both, prints a comparison.
set -euo pipefail
cd "$(dirname "$0")"

echo ">> Creating pods..."
kubectl apply -f 01-emptydir-disk.yaml -f 02-emptydir-memory.yaml
kubectl wait --for=condition=Ready pod/emptydir-disk pod/emptydir-memory --timeout=120s

for p in emptydir-disk emptydir-memory; do
  echo
  echo "################ $p ################"
  kubectl exec "$p" -- sh -c 'echo -n "Mount: "; mount | grep /scratch'
  kubectl exec -i "$p" -- sh -s /scratch < benchmark.sh | tee "/tmp/$p.out"
done

read -r _ dw dr ds < <(grep RESULT /tmp/emptydir-disk.out)
read -r _ mw mr ms < <(grep RESULT /tmp/emptydir-memory.out)

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b==0) b=1; printf "%.1fx", a/b }'; }

echo
echo "================= COMPARISON (lower ms = faster) ================="
printf "%-28s %10s %10s %10s\n" "Test" "Disk(ms)" "RAM(ms)" "RAM faster"
printf "%-28s %10s %10s %10s\n" "Sequential write + fsync" "$dw" "$mw" "$(ratio "$dw" "$mw")"
printf "%-28s %10s %10s %10s\n" "Sequential read"          "$dr" "$mr" "$(ratio "$dr" "$mr")"
printf "%-28s %10s %10s %10s\n" "Small files + fsync"      "$ds" "$ms" "$(ratio "$ds" "$ms")"
echo "=================================================================="
echo
echo ">> Memory usage of the RAM pod (tmpfs files count here):"
kubectl top pod emptydir-memory 2>/dev/null || echo "   (metrics-server not installed; skip)"
