#!/bin/bash
# =====================================================================
# 99-delete-all.sh   (HA VM or laptop / Cloud Shell)  - deletes EVERYTHING (stops billing)
#     bash 99-delete-all.sh
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"
read -rp "Delete resource group '${RG}' and ALL VMs in it? Type the RG name to confirm: " c
[ "$c" = "${RG}" ] || { echo "Cancelled"; exit 1; }
az group delete -n "${RG}" --yes --no-wait
echo "Deletion started (takes a few minutes): az group show -n ${RG}"
