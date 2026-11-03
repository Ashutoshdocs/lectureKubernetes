
#!/bin/bash

# ==========================================
# KUBERNETES CLUSTER - AZURE INFRASTRUCTURE
# ==========================================

# Variables
RG="rg-k8s-cluster"
LOCATION="centralindia"

VNET="vnet-k8s"
SUBNET="subnet-k8s"

ADMIN_USER="azureuser"
ADMIN_PASSWORD="ChangeMe@12345!"

# ==========================================
# 1. CREATE RESOURCE GROUP
# ==========================================

az group create \
  --name $RG \
  --location $LOCATION

# ==========================================
# 2. CREATE VNET AND SUBNET
# ==========================================

az network vnet create \
  --resource-group $RG \
  --name $VNET \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET \
  --subnet-prefix 10.0.1.0/24

# ==========================================
# 3. CREATE CONTROL PLANE VM - B2S
# ==========================================

az vm create \
  --resource-group $RG \
  --name controlplanevm \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size Standard_B2s \
  --vnet-name $VNET \
  --subnet $SUBNET \
  --admin-username $ADMIN_USER \
  --admin-password "$ADMIN_PASSWORD" \
  --authentication-type password \
  --public-ip-sku Standard \
  --output table

# ==========================================
# 4. CREATE WORKER 01 - B1S
# ==========================================

az vm create \
  --resource-group $RG \
  --name worker01 \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size Standard_B1s \
  --vnet-name $VNET \
  --subnet $SUBNET \
  --admin-username $ADMIN_USER \
  --admin-password "$ADMIN_PASSWORD" \
  --authentication-type password \
  --public-ip-sku Standard \
  --output table

# ==========================================
# 5. CREATE WORKER 02 - B1S
# ==========================================

az vm create \
  --resource-group $RG \
  --name worker02 \
  --location $LOCATION \
  --image Ubuntu2404 \
  --size Standard_B1s \
  --vnet-name $VNET \
  --subnet $SUBNET \
  --admin-username $ADMIN_USER \
  --admin-password "$ADMIN_PASSWORD" \
  --authentication-type password \
  --public-ip-sku Standard \
  --output table

# ==========================================
# 6. DISPLAY ALL VMS
# ==========================================

az vm list \
  --resource-group $RG \
  --show-details \
  --output table

echo "===================================="
echo "Kubernetes Infrastructure Created!"
echo "===================================="
