#!/usr/bin/env bash
# Creates the AKS cluster used by this demo. Override any variable before running:
#   RG=my-rg LOCATION=southindia ./scripts/00-create-aks.sh
set -euo pipefail

RG=${RG:-rg-pg-failover-demo}
LOCATION=${LOCATION:-centralindia}
CLUSTER=${CLUSTER:-aks-pg-failover}
NODE_COUNT=${NODE_COUNT:-3}
NODE_SIZE=${NODE_SIZE:-Standard_D2s_v5}

echo ">> Registering resource providers (no-op if already registered)"
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.Network --wait

echo ">> Creating resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" -o table

echo ">> Creating AKS cluster $CLUSTER ($NODE_COUNT x $NODE_SIZE) - takes ~5-10 min"
az aks create \
  --resource-group "$RG" \
  --name "$CLUSTER" \
  --location "$LOCATION" \
  --tier free \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_SIZE" \
  --enable-managed-identity \
  --generate-ssh-keys \
  -o table

echo ">> Fetching kubeconfig"
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing

echo ">> Cluster ready"
kubectl get nodes -o wide
kubectl get storageclass
