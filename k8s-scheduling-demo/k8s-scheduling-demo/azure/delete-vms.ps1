<#
.SYNOPSIS
    Deletes everything created by create-vms.ps1 (the whole resource group).
#>
param(
    [string]$ResourceGroup = "rg-k8s-scheduling-demo",
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

az group show --name $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Resource group '$ResourceGroup' does not exist." -ForegroundColor Yellow; return }

az resource list --resource-group $ResourceGroup --query "[].{Name:name, Type:type}" --output table

if (-not $Force) {
    $answer = Read-Host "Delete resource group '$ResourceGroup' and ALL resources above? Type the RG name to confirm"
    if ($answer -ne $ResourceGroup) { Write-Host "Aborted." -ForegroundColor Yellow; return }
}
az group delete --name $ResourceGroup --yes --no-wait
Write-Host "Deletion started (runs in background, ~5-10 min). Check: az group show -n $ResourceGroup" -ForegroundColor Green
