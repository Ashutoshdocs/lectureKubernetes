#!/usr/bin/env bash
###############################################################################
# 99-cleanup.sh  -- delete EVERYTHING (all 6 VMs, network, disks, IPs).
# Run from your laptop when the lab is over so you stop paying for it.
###############################################################################
set -euo pipefail
RG="k8s-haproxy-rg"
echo ">> Deleting resource group $RG and all resources in it..."
az group delete --name "$RG" --yes --no-wait
echo ">> Deletion started (running in background)."
