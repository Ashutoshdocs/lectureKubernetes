#######################################################
# AKS Deployment Script (PowerShell)
#######################################################

# Login
az login

# Set Subscription
$SUBSCRIPTION = "6f787beb-8095-4923-ae3e-deba86057045"
az account set --subscription $SUBSCRIPTION

# Variables
$RG = "aks-demo-rg"
$LOCATION = "centralindia"
$AKS = "aks-demo"

# Create Resource Group
az group create `
    --name $RG `
    --location $LOCATION

# Create AKS Cluster
az aks create `
    --resource-group $RG `
    --name $AKS `
    --location $LOCATION `
    --node-count 1 `
    --node-vm-size Standard_B2s `
    --generate-ssh-keys `
    --tier free

# Create folder for kubeconfig
New-Item -ItemType Directory -Path "D:\credsaks" -Force

# Download kubeconfig to D:\credsaks
az aks get-credentials `
    --resource-group $RG `
    --name $AKS `
    --file "D:\credsaks\config" `
    --overwrite-existing

# Tell kubectl to use this kubeconfig
$env:KUBECONFIG = "D:\credsaks\config"

# Verify connection
kubectl cluster-info

kubectl get nodes -o wide

kubectl get pods -A