# ============================================================
# Delete the whole Azure Kubernetes Access Modes Lab
# (resource group, 4 VMs, disks, public IPs, VNet, NSG)
# ============================================================

$RG = "rg-k8s-access-modes"

$answer = Read-Host "This permanently deletes resource group '$RG' and everything in it. Type YES to continue"
if ($answer -ne "YES") {
    Write-Host "Cancelled."
    exit 0
}

az group delete --name $RG --yes --no-wait
Write-Host "Deletion started in the background. Check with: az group show -n $RG"
