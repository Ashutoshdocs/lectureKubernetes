#######################################################
# 02 - Create the Azure managed disk for STATIC provisioning
#######################################################
# Run this before applying static/azure-pv.yaml.

$RG = "aks-demo-rg"

# Create a 4 GiB standard managed disk
az disk create `
    --resource-group $RG `
    --name demoDisk `
    --size-gb 4 `
    --sku Standard_LRS

# Grab the disk resource ID — paste this into volumeHandle in static/azure-pv.yaml
$DISK_ID = az disk show --resource-group $RG --name demoDisk --query id -o tsv
Write-Host "Disk ID:  $DISK_ID"
