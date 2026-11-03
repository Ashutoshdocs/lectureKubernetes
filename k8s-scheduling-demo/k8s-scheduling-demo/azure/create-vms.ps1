<#
.SYNOPSIS
    Creates 6 Trusted Launch Ubuntu 22.04 (Gen2) VMs - Standard_B2s, password auth -
    for a kubeadm Kubernetes scheduling demo.

.DESCRIPTION
    Layout (matches the Kubernetes demo):
        k8s-master   10.10.1.10   control plane   (no k8s zone label)
        worker-a1    10.10.1.11   zone-a
        worker-a2    10.10.1.12   zone-a
        worker-a3    10.10.1.13   zone-a
        worker-b1    10.10.1.21   zone-b
        worker-b2    10.10.1.22   zone-b

    Trusted Launch = Gen2 image + Secure Boot + vTPM (+ optional integrity monitoring).
    Each VM gets cloud-init (cloud-init-k8s.yaml) that installs containerd, kubeadm,
    kubelet and kubectl, so the VMs are ready for "kubeadm init / join".

.EXAMPLE
    ./create-vms.ps1
.EXAMPLE
    ./create-vms.ps1 -Location centralindia -UseAzureZones -AutoShutdownUtc 1630
.NOTES
    Requires Azure CLI 2.50+ (az --version). Run from PowerShell 7+ (recommended) or Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId = "",
    [string]$ResourceGroup  = "rg-k8s-scheduling-demo",
    [string]$Location       = "centralindia",
    [string]$AdminUser      = "azureuser",
    [string]$VmSize         = "Standard_B2s",
    # Gen2 image is REQUIRED for Trusted Launch
    [string]$Image          = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest",
    [string]$VnetName       = "vnet-k8s",
    [string]$SubnetName     = "snet-k8s",
    [string]$NsgName        = "nsg-k8s",
    [string]$CloudInitFile  = "cloud-init-k8s.yaml",
    # Also place zone-a VMs in Azure AZ 1 and zone-b VMs in Azure AZ 2 (optional, real fault domains)
    [switch]$UseAzureZones,
    # Install Guest Attestation extension (integrity monitoring) - part of Trusted Launch, on by default
    [bool]$EnableIntegrityMonitoring = $true,
    # Optional daily auto-shutdown time in UTC, e.g. "1630" (= 22:00 IST). Empty = disabled.
    [string]$AutoShutdownUtc = ""
)

$ErrorActionPreference = 'Stop'

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI step failed: $What (exit code $LASTEXITCODE)" }
}

# ---------------------------------------------------------------- VM definitions
$vms = @(
    @{ Name = 'k8s-master'; Ip = '10.10.1.10'; Role = 'control-plane'; Zone = 'none';   AzZone = '1' }
    @{ Name = 'worker-a1';  Ip = '10.10.1.11'; Role = 'worker';        Zone = 'zone-a'; AzZone = '1' }
    @{ Name = 'worker-a2';  Ip = '10.10.1.12'; Role = 'worker';        Zone = 'zone-a'; AzZone = '1' }
    @{ Name = 'worker-a3';  Ip = '10.10.1.13'; Role = 'worker';        Zone = 'zone-a'; AzZone = '1' }
    @{ Name = 'worker-b1';  Ip = '10.10.1.21'; Role = 'worker';        Zone = 'zone-b'; AzZone = '2' }
    @{ Name = 'worker-b2';  Ip = '10.10.1.22'; Role = 'worker';        Zone = 'zone-b'; AzZone = '2' }
)

# ---------------------------------------------------------------- Pre-checks
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install it from https://aka.ms/installazurecli"
}

$cloudInitPath = Join-Path $PSScriptRoot $CloudInitFile
if (-not (Test-Path $cloudInitPath)) { throw "cloud-init file not found: $cloudInitPath" }
$cloudInitPath = (Resolve-Path $cloudInitPath).Path

az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in - opening az login..." -ForegroundColor Yellow
    az login --output none; Assert-LastExit "az login"
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId; Assert-LastExit "az account set" }
$subName = az account show --query name -o tsv
Write-Host "Using subscription: $subName" -ForegroundColor Cyan

# Check the VM size is offered (and not restricted) in this region
$skuJson = az vm list-skus --location $Location --size $VmSize --resource-type virtualMachines --all --output json | ConvertFrom-Json
Assert-LastExit "az vm list-skus"
$sku = $skuJson | Where-Object { $_.name -eq $VmSize } | Select-Object -First 1
if (-not $sku) { throw "$VmSize is not available in $Location. Try another region (e.g. southindia, eastus)." }
if ($sku.restrictions | Where-Object { $_.reasonCode -eq 'NotAvailableForSubscription' -and $_.type -eq 'Location' }) {
    throw "$VmSize is restricted for your subscription in $Location. Try another region."
}
if ($UseAzureZones) {
    $zones = @($sku.locationInfo[0].zones)
    foreach ($z in @('1','2')) {
        if ($zones -notcontains $z) { throw "$VmSize is not offered in Azure zone $z in $Location. Re-run without -UseAzureZones." }
    }
}

# ---------------------------------------------------------------- Password (never echoed)
$sec1 = Read-Host "Admin password for '$AdminUser' (12-72 chars, 3 of: upper/lower/digit/special)" -AsSecureString
$sec2 = Read-Host "Confirm password" -AsSecureString
$pw   = [System.Net.NetworkCredential]::new('', $sec1).Password
$pw2  = [System.Net.NetworkCredential]::new('', $sec2).Password
if ($pw -cne $pw2) { throw "Passwords do not match." }

$classes = 0
if ($pw -cmatch '[a-z]')        { $classes++ }
if ($pw -cmatch '[A-Z]')        { $classes++ }
if ($pw -match  '\d')           { $classes++ }
if ($pw -match  '[^a-zA-Z0-9]') { $classes++ }
if ($pw.Length -lt 12 -or $pw.Length -gt 72 -or $classes -lt 3) {
    throw "Password must be 12-72 characters and contain 3 of: lowercase, uppercase, digit, special character."
}
# az on Windows is a .cmd wrapper - these characters get mangled by cmd.exe
if ($pw -match '["`&|<>^%]') {
    throw "Please avoid these characters in the password: `" `` & | < > ^ %  (they break az.cmd on Windows). Use e.g. ! @ # * - _ + = ."
}
$pw2 = $null

# ---------------------------------------------------------------- Your public IP for SSH
try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).ToString().Trim()
    $sshSource = "$myIp/32"
    Write-Host "SSH will be allowed only from your IP: $sshSource" -ForegroundColor Cyan
} catch {
    $sshSource = '*'
    Write-Warning "Could not detect your public IP - SSH will be open to the Internet (*). Tighten the NSG rule later."
}

# ---------------------------------------------------------------- Network
Write-Host "`n[1/4] Resource group $ResourceGroup ($Location)" -ForegroundColor Green
az group create --name $ResourceGroup --location $Location --tags purpose=k8s-scheduling-demo --output none
Assert-LastExit "group create"

Write-Host "[2/4] NSG $NsgName (SSH from $sshSource; all VNet-internal traffic allowed by default rules)" -ForegroundColor Green
az network nsg create --resource-group $ResourceGroup --name $NsgName --output none
Assert-LastExit "nsg create"
az network nsg rule create --resource-group $ResourceGroup --nsg-name $NsgName --name Allow-SSH `
    --priority 1000 --direction Inbound --access Allow --protocol Tcp `
    --source-address-prefixes $sshSource --source-port-ranges '*' `
    --destination-address-prefixes '*' --destination-port-ranges 22 --output none
Assert-LastExit "nsg rule create"

Write-Host "[3/4] VNet $VnetName 10.10.0.0/16, subnet $SubnetName 10.10.1.0/24" -ForegroundColor Green
az network vnet create --resource-group $ResourceGroup --name $VnetName `
    --address-prefixes 10.10.0.0/16 --subnet-name $SubnetName --subnet-prefixes 10.10.1.0/24 --output none
Assert-LastExit "vnet create"

# ---------------------------------------------------------------- VMs
Write-Host "[4/4] Creating $($vms.Count) Trusted Launch VMs ($VmSize) - ~2-3 min each" -ForegroundColor Green
foreach ($vm in $vms) {
    Write-Host "  -> $($vm.Name)  $($vm.Ip)  [$($vm.Role) / $($vm.Zone)]" -ForegroundColor Yellow

    $azArgs = @(
        'vm', 'create',
        '--resource-group',        $ResourceGroup,
        '--name',                  $vm.Name,
        '--computer-name',         $vm.Name,           # hostname = Kubernetes node name
        '--location',              $Location,
        '--image',                 $Image,
        '--size',                  $VmSize,
        '--authentication-type',   'password',
        '--admin-username',        $AdminUser,
        '--admin-password',        $pw,
        # ---- Trusted Launch ----
        '--security-type',         'TrustedLaunch',
        '--enable-secure-boot',    'true',
        '--enable-vtpm',           'true',
        # ---- Network ----
        '--vnet-name',             $VnetName,
        '--subnet',                $SubnetName,
        '--private-ip-address',    $vm.Ip,
        '--nsg',                   $NsgName,
        '--public-ip-address',     "$($vm.Name)-pip",
        '--public-ip-sku',         'Standard',
        # ---- Disk / bootstrap ----
        '--os-disk-name',          "$($vm.Name)-osdisk",
        '--os-disk-size-gb',       '30',
        '--storage-sku',           'StandardSSD_LRS',
        '--custom-data',           $cloudInitPath,
        '--tags',                  "role=$($vm.Role)", "k8s-zone=$($vm.Zone)",
        '--output',                'none'
    )
    if ($UseAzureZones)             { $azArgs += @('--zone', $vm.AzZone) }
    if ($EnableIntegrityMonitoring) { $azArgs += '--enable-integrity-monitoring' }

    az @azArgs
    Assert-LastExit "vm create $($vm.Name)"

    if ($AutoShutdownUtc) {
        az vm auto-shutdown --resource-group $ResourceGroup --name $vm.Name --time $AutoShutdownUtc --output none
        Assert-LastExit "auto-shutdown $($vm.Name)"
    }
}
$pw = $null

# ---------------------------------------------------------------- Verify
Write-Host "`nTrusted Launch verification:" -ForegroundColor Green
az vm list --resource-group $ResourceGroup `
    --query "[].{Name:name, Size:hardwareProfile.vmSize, Security:securityProfile.securityType, SecureBoot:securityProfile.uefiSettings.secureBootEnabled, vTPM:securityProfile.uefiSettings.vTpmEnabled, AzZone:zones[0]}" `
    --output table

Write-Host "`nIP addresses:" -ForegroundColor Green
az vm list --resource-group $ResourceGroup --show-details `
    --query "[].{Name:name, PublicIP:publicIps, PrivateIP:privateIps}" --output table

Write-Host @"

Done. Next steps (see README.md):
  1. ssh $AdminUser@<k8s-master-public-ip>
  2. cloud-init status --wait        # wait until node prep finishes (~3-5 min)
  3. sudo kubeadm init --apiserver-advertise-address=10.10.1.10 --pod-network-cidr=10.244.0.0/16
  4. Join the 5 workers, install Flannel, then run the demo.

Cleanup when finished:  az group delete --name $ResourceGroup --yes --no-wait
"@ -ForegroundColor Cyan
