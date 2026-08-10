
$ErrorActionPreference = "Stop"

# ==========================================
# AKS LOADBALANCER DEMO
# ==========================================

$RESOURCE_GROUP = "rg-aks-lb-demo"
$LOCATION = "centralindia"
$AKS_NAME = "aks-lb-demo"
$NODE_COUNT = 2

# Kubeconfig will be stored in THIS project directory
$KUBECONFIG_FILE = Join-Path (Get-Location) "aks-kubeconfig"

Write-Host "======================================"
Write-Host "       AKS LOADBALANCER DEMO"
Write-Host "======================================"

# ==========================================
# 1. CHECK AZURE LOGIN
# ==========================================

Write-Host ""
Write-Host "[1/5] Checking Azure login..."

az account show

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Azure login not found."
    Write-Host "Run: az login"
    exit 1
}

# ==========================================
# 2. CREATE RESOURCE GROUP
# ==========================================

Write-Host ""
Write-Host "[2/5] Creating Resource Group..."

az group create `
    --name $RESOURCE_GROUP `
    --location $LOCATION

# ==========================================
# 3. CREATE AKS
# ==========================================

Write-Host ""
Write-Host "[3/5] Creating AKS..."

az aks create `
    --resource-group $RESOURCE_GROUP `
    --name $AKS_NAME `
    --location $LOCATION `
    --node-count $NODE_COUNT `
    --node-vm-size "Standard_B2s" `
    --generate-ssh-keys

# ==========================================
# 4. DOWNLOAD KUBECONFIG
# ==========================================

Write-Host ""
Write-Host "[4/5] Downloading kubeconfig..."

az aks get-credentials `
    --resource-group $RESOURCE_GROUP `
    --name $AKS_NAME `
    --file $KUBECONFIG_FILE `
    --overwrite-existing

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to download kubeconfig."
    exit 1
}

# ==========================================
# 5. SET KUBECONFIG
# ==========================================

Write-Host ""
Write-Host "[5/5] Configuring kubectl..."

$env:KUBECONFIG = $KUBECONFIG_FILE

Write-Host ""
Write-Host "Testing Kubernetes cluster..."
Write-Host ""

kubectl get nodes

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "kubectl could not connect to AKS."
    exit 1
}

# ==========================================
# SUCCESS
# ==========================================

Write-Host ""
Write-Host "======================================"
Write-Host "            SUCCESS"
Write-Host "======================================"

Write-Host ""
Write-Host "Resource Group : $RESOURCE_GROUP"
Write-Host "AKS Cluster    : $AKS_NAME"
Write-Host "Location       : $LOCATION"
Write-Host "Node Count     : $NODE_COUNT"

Write-Host ""
Write-Host "Kubeconfig:"
Write-Host $KUBECONFIG_FILE

Write-Host ""
Write-Host "KUBECONFIG environment variable:"
Write-Host $env:KUBECONFIG

Write-Host ""
Write-Host "======================================"
Write-Host "Use kubectl normally now:"
Write-Host "======================================"

Write-Host ""
Write-Host "kubectl get nodes"
Write-Host "kubectl get pods -A"
Write-Host "kubectl get svc"

Write-Host ""
Write-Host "======================================"
Write-Host "AKS SETUP COMPLETED"
Write-Host "======================================"

