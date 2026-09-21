#!/usr/bin/env bash
# Runs every demo scenario in sequence with pauses, so you can watch the
# alerts land in your `make logs` terminal one at a time.
set -euo pipefail
cd "$(dirname "$0")"

pause() { echo; read -rp "  ↵ press enter for the next scenario... " _ || true; echo; }

echo "======================================================================"
echo " Falco demo — keep 'make logs' open in another terminal to watch alerts"
echo "======================================================================"

echo; echo "### Scenario 1: shell in container"
./01-shell-in-container.sh
pause

echo "### Scenario 2: read sensitive file"
./02-read-sensitive-file.sh
pause

echo "### Scenario 3: write below /etc"
./03-write-below-etc.sh
pause

echo "### Scenario 4: package manager in container"
./04-package-mgmt.sh
pause

echo "### Scenario 5: crypto-miner simulation"
kubectl apply -f 05-crypto-miner-sim.yaml
echo "    (miner-sim pod started; the CRITICAL alert should appear within ~1s)"
sleep 5
kubectl delete -f 05-crypto-miner-sim.yaml --ignore-not-found

echo
echo "[✓] All scenarios complete. Check the Falco stream / Falcosidekick UI."
