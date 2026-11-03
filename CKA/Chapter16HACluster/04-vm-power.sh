#!/bin/bash
# =====================================================================
# 04-vm-power.sh   (HA VM after "az login", or laptop / Cloud Shell)
#
#   bash 04-vm-power.sh stop  vm-k8s-cp1     # simulate control plane failure
#   bash 04-vm-power.sh start vm-k8s-cp1     # bring it back
#   bash 04-vm-power.sh status               # power state of all VMs
#
# 'stop' = power off (like pulling the plug). The VM keeps its private IP.
# =====================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

ACTION=$1; VM=$2

case "$ACTION" in
  stop)
    [ -n "$VM" ] || { echo "Usage: $0 stop <vm-name>"; exit 1; }
    echo "=== Powering OFF ${VM} (simulated failure) ==="
    az vm stop -g "${RG}" -n "${VM}" --skip-shutdown -o none
    echo "Done. Watch 03-watch-cluster.sh on another control plane."
    ;;
  start)
    [ -n "$VM" ] || { echo "Usage: $0 start <vm-name>"; exit 1; }
    echo "=== Starting ${VM} ==="
    az vm start -g "${RG}" -n "${VM}" -o none
    echo "Done. kubelet starts etcd + apiserver automatically (static pods)."
    ;;
  status)
    az vm list -g "${RG}" -d --query "[].{VM:name, Power:powerState, PrivateIP:privateIps, PublicIP:publicIps}" -o table
    ;;
  *)
    echo "Usage: $0 stop|start <vm-name>   |   $0 status"; exit 1 ;;
esac
