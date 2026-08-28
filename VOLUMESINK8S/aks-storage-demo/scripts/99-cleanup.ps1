#######################################################
# 99 - Tear everything down
#######################################################

$env:KUBECONFIG = "D:\credsaks\config"
$RG = "aks-demo-rg"

# --- Dynamic demo ---
kubectl delete pod dynamic-demo --ignore-not-found
kubectl delete pvc dynamic-pvc --ignore-not-found
# (the disk backing dynamic-pvc is deleted automatically with the PVC)

# --- Static demo ---
kubectl delete pod storage-demo --ignore-not-found
kubectl delete pvc azure-pvc --ignore-not-found
kubectl delete pv azure-pv --ignore-not-found
# Reclaim policy is Retain, so the disk is NOT auto-deleted — remove it by hand:
az disk delete --resource-group $RG --name demoDisk --yes

# --- Everything (optional): delete the whole cluster/resource group ---
# az group delete --name $RG --yes --no-wait
