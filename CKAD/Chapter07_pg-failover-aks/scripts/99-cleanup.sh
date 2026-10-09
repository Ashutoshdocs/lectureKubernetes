#!/usr/bin/env bash
# Deletes EVERYTHING (cluster, disks, file shares, public IP) by deleting the resource group.
set -euo pipefail
RG=${RG:-rg-pg-failover-demo}
echo "Deleting resource group $RG (and the AKS-managed MC_* group) ..."
az group delete --name "$RG" --yes --no-wait
echo "Deletion started. Check with: az group show -n $RG"
