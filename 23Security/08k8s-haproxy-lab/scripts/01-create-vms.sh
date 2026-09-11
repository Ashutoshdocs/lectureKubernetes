#!/usr/bin/env bash
###############################################################################
# 01-create-vms.sh
#
# Creates all 6 VMs for the lab on Azure using PASSWORD authentication.
#
#   haproxy-vm      -> HAProxy load balancer / router (the single entry point)
#   cluster1-cp     -> Cluster 1 control plane  (API server 1)  -> Manohar
#   cluster1-worker -> Cluster 1 worker node    (worker 1)
#   cluster2-cp     -> Cluster 2 control plane  (API server 2)  -> Ashutosh
#   cluster2-worker -> Cluster 2 worker node    (worker 2)
#   clusterwork     -> Jump/bastion box. Manohar & Ashutosh SSH here and run
#                      kubectl. It NEVER talks to an API server directly, only
#                      through HAProxy.
#
# All VMs share one VNet, so traffic between them is allowed by default.
# Run this from your laptop (needs: az login already done).
###############################################################################
set -euo pipefail

########## EDIT THESE ##########
RG="k8s-haproxy-rg"
LOCATION="centralindia"          # pick a region near you
ADMIN_USER="azureuser"           # OS admin login for YOU (the instructor)
ADMIN_PASS="ChangeMe_Str0ng!2026"  # Azure rule: 12-72 chars, 3 of 4 char classes
IMAGE="Ubuntu2204"
SIZE_CP="Standard_B2s"           # 2 vCPU / 4 GB  (control planes need >=2 vCPU)
SIZE_WORKER="Standard_B2s"       # 2 vCPU / 4 GB
SIZE_SMALL="Standard_B1ms"       # 1 vCPU / 2 GB  (haproxy + bastion)
VNET="k8s-vnet"
SUBNET="k8s-subnet"
################################

echo ">> Creating resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" -o table

echo ">> Creating VNet + subnet"
az network vnet create \
  --resource-group "$RG" --name "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefix 10.0.1.0/24 -o table

create_vm () {
  local name="$1" size="$2"
  echo ">> Creating VM: $name ($size)"
  az vm create \
    --resource-group "$RG" \
    --name "$name" \
    --image "$IMAGE" \
    --size "$size" \
    --vnet-name "$VNET" \
    --subnet "$SUBNET" \
    --admin-username "$ADMIN_USER" \
    --authentication-type password \
    --admin-password "$ADMIN_PASS" \
    --public-ip-sku Standard \
    -o table
}

create_vm haproxy-vm      "$SIZE_SMALL"
create_vm cluster1-cp     "$SIZE_CP"
create_vm cluster1-worker "$SIZE_WORKER"
create_vm cluster2-cp     "$SIZE_CP"
create_vm cluster2-worker "$SIZE_WORKER"
create_vm clusterwork     "$SIZE_SMALL"

echo ">> Opening HAProxy ports (7001 = cluster1, 7002 = cluster2, 8404 = stats)"
az vm open-port --resource-group "$RG" --name haproxy-vm --port 7001 --priority 1001
az vm open-port --resource-group "$RG" --name haproxy-vm --port 7002 --priority 1002
az vm open-port --resource-group "$RG" --name haproxy-vm --port 8404 --priority 1003

echo
echo "=================  IP ADDRESSES  ================="
az vm list-ip-addresses --resource-group "$RG" \
  --query "[].{VM:virtualMachine.name, Public:virtualMachine.network.publicIpAddresses[0].ipAddress, Private:virtualMachine.network.privateIpAddresses[0]}" \
  -o table
echo "=================================================="
echo
echo "Copy these into env.sh (see env.sh.example). SSH into any VM with:"
echo "   ssh $ADMIN_USER@<PUBLIC_IP>      (password: the one you set above)"
