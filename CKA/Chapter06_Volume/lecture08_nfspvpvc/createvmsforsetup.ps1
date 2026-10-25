# ============================================================
# Azure Kubernetes + NFS Lab
# 3 VMs:
#   NFS VM          = 10.0.1.4
#   Control Plane   = 10.0.1.5
#   Worker          = 10.0.1.6
# ============================================================

$RG       = "rg-k8s-nfs"
$LOCATION = "centralindia"

$VNET     = "vnet-k8s"
$SUBNET   = "subnet-k8s"
$NSG      = "nsg-k8s"

$NFS_VM   = "nfs-vm"
$CP_VM    = "k8s-control-plane"
$WORKER_VM = "k8s-worker"

$NFS_IP   = "10.0.1.4"
$CP_IP    = "10.0.1.5"
$WORKER_IP = "10.0.1.6"

$ADMIN_USER = "azureuser"

# ------------------------------------------------------------
# Ask for VM password
# ------------------------------------------------------------

$PASSWORD = Read-Host "Enter password for all VMs" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PASSWORD)
$PLAIN_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

Write-Host ""
Write-Host "============================================================"
Write-Host " Creating Azure Kubernetes + NFS Lab"
Write-Host "============================================================"

# ------------------------------------------------------------
# 1. Create Resource Group
# ------------------------------------------------------------

Write-Host "[1/7] Creating Resource Group..."

az group create `
    --name $RG `
    --location $LOCATION `
    --output none

# ------------------------------------------------------------
# 2. Create VNet + Subnet
# ------------------------------------------------------------

Write-Host "[2/7] Creating VNet and Subnet..."

az network vnet create `
    --resource-group $RG `
    --name $VNET `
    --location $LOCATION `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $SUBNET `
    --subnet-prefix 10.0.1.0/24 `
    --output none

# ------------------------------------------------------------
# 3. Create NSG
# ------------------------------------------------------------

Write-Host "[3/7] Creating Network Security Group..."

az network nsg create `
    --resource-group $RG `
    --name $NSG `
    --location $LOCATION `
    --output none

# ------------------------------------------------------------
# Allow SSH
# ------------------------------------------------------------

Write-Host "      Allowing SSH on port 22..."

az network nsg rule create `
    --resource-group $RG `
    --nsg-name $NSG `
    --name Allow-SSH `
    --priority 100 `
    --access Allow `
    --protocol Tcp `
    --direction Inbound `
    --source-address-prefixes "*" `
    --destination-port-ranges 22 `
    --output none

# ------------------------------------------------------------
# 4. Create NFS VM
# ------------------------------------------------------------

Write-Host "[4/7] Creating NFS VM..."
Write-Host "      Private IP: $NFS_IP"

az vm create `
    --resource-group $RG `
    --name $NFS_VM `
    --location $LOCATION `
    --image Ubuntu2204 `
    --size Standard_B2s `
    --admin-username $ADMIN_USER `
    --admin-password $PLAIN_PASSWORD `
    --authentication-type password `
    --vnet-name $VNET `
    --subnet $SUBNET `
    --private-ip-address $NFS_IP `
    --nsg $NSG `
    --public-ip-sku Standard `
    --output none

# ------------------------------------------------------------
# 5. Create Control Plane VM
# ------------------------------------------------------------

Write-Host "[5/7] Creating Kubernetes Control Plane..."
Write-Host "      Private IP: $CP_IP"

az vm create `
    --resource-group $RG `
    --name $CP_VM `
    --location $LOCATION `
    --image Ubuntu2204 `
    --size Standard_B2s `
    --admin-username $ADMIN_USER `
    --admin-password $PLAIN_PASSWORD `
    --authentication-type password `
    --vnet-name $VNET `
    --subnet $SUBNET `
    --private-ip-address $CP_IP `
    --nsg $NSG `
    --public-ip-sku Standard `
    --output none

# ------------------------------------------------------------
# 6. Create Worker VM
# ------------------------------------------------------------

Write-Host "[6/7] Creating Kubernetes Worker..."
Write-Host "      Private IP: $WORKER_IP"

az vm create `
    --resource-group $RG `
    --name $WORKER_VM `
    --location $LOCATION `
    --image Ubuntu2204 `
    --size Standard_B2s `
    --admin-username $ADMIN_USER `
    --admin-password $PLAIN_PASSWORD `
    --authentication-type password `
    --vnet-name $VNET `
    --subnet $SUBNET `
    --private-ip-address $WORKER_IP `
    --nsg $NSG `
    --public-ip-sku Standard `
    --output none

# ------------------------------------------------------------
# 7. Display VM IP Information
# ------------------------------------------------------------

Write-Host "[7/7] Getting VM IP addresses..."

Write-Host ""
Write-Host "============================================================"
Write-Host " VM IP INFORMATION"
Write-Host "============================================================"

az vm list-ip-addresses `
    --resource-group $RG `
    --output table

Write-Host ""
Write-Host "============================================================"
Write-Host " LAB CREATED SUCCESSFULLY"
Write-Host "============================================================"
Write-Host ""
Write-Host "NFS VM"
Write-Host "  Name       : $NFS_VM"
Write-Host "  Private IP : $NFS_IP"
Write-Host ""
Write-Host "Control Plane"
Write-Host "  Name       : $CP_VM"
Write-Host "  Private IP : $CP_IP"
Write-Host ""
Write-Host "Worker"
Write-Host "  Name       : $WORKER_VM"
Write-Host "  Private IP : $WORKER_IP"
Write-Host ""
Write-Host "Username    : $ADMIN_USER"
Write-Host "Password    : <the password you entered>"
Write-Host ""
Write-Host "============================================================"
Write-Host " SSH EXAMPLES"
Write-Host "============================================================"
Write-Host ""
Write-Host "az vm ssh -g $RG -n $NFS_VM"
Write-Host "az vm ssh -g $RG -n $CP_VM"
Write-Host "az vm ssh -g $RG -n $WORKER_VM"
Write-Host ""
Write-Host "============================================================"