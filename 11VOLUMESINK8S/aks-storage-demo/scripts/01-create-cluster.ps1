#######################################################
# 01 - AKS cluster deployment (PowerShell)
#######################################################

# --- Login ---
az login

# --- Subscription ---
$SUBSCRIPTION = "6f787beb-8095-4923-ae3e-deba86057045"
az account set --subscription $SUBSCRIPTION

# --- Variables ---
$RG       = "aks-demo-rg"
$LOCATION = "centralindia"
$AKS      = "aks-demo"

# --- Resource group ---
az group create `
    --name $RG `
    --location $LOCATION

# --- AKS cluster ---
az aks create `
    --resource-group $RG `
    --name $AKS `
    --location $LOCATION `
    --node-count 1 `
    --node-vm-size Standard_B2s `
    --generate-ssh-keys `
    --tier free

# --- Kubeconfig ---
New-Item -ItemType Directory -Path "D:\credsaks" -Force

az aks get-credentials `
    --resource-group $RG `
    --name $AKS `
    --file "D:\credsaks\config" `
    --overwrite-existing

$env:KUBECONFIG = "D:\credsaks\config"

# --- Verify ---
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
