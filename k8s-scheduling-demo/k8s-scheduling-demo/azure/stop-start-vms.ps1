<#
.SYNOPSIS
    Deallocate (stop billing for compute) or start all demo VMs.
.EXAMPLE
    ./stop-start-vms.ps1 -Action stop
    ./stop-start-vms.ps1 -Action start
#>
param(
    [Parameter(Mandatory)][ValidateSet('start','stop')][string]$Action,
    [string]$ResourceGroup = "rg-k8s-scheduling-demo"
)
$ids = az vm list --resource-group $ResourceGroup --query "[].id" -o tsv
if (-not $ids) { Write-Host "No VMs found in $ResourceGroup"; return }
if ($Action -eq 'stop') { az vm deallocate --ids $ids --no-wait } else { az vm start --ids $ids --no-wait }
Write-Host "$Action requested for all VMs in $ResourceGroup."
