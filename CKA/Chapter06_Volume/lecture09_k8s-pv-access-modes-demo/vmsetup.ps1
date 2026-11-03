
# ==============================================
# AZURE KUBERNETES INFRASTRUCTURE SETUP
# 1 Control Plane + 2 Worker VMs
# ==============================================

$RG = "rg-k8s-cluster"
$LOCATION = "centralindia"
$VNET = "vnet-k8s"
$SUBNET = "subnet-k8s"
$ADMIN_USER = "azureuser"

# Ask for VM password securely
$SecurePassword = Read-Host "Enter VM Admin Password" -AsSecureString
$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

try {

    # 1. Create Resource Group
    az group create --name $RG --location $LOCATION --output table
    if ($LASTEXITCODE -ne 0) { throw "Resource Group creation failed" }

    # 2. Create VNet and Subnet
    az network vnet create --resource-group $RG --name $VNET --address-prefix 10.0.0.0/16 --subnet-name $SUBNET --subnet-prefix 10.0.1.0/24 --output table
    if ($LASTEXITCODE -ne 0) { throw "VNet creation failed" }

    # 3. Create Control Plane VM - B2s
    az vm create --resource-group $RG --name controlplanevm --location $LOCATION --image Ubuntu2404 --size Standard_B2s --vnet-name $VNET --subnet $SUBNET --admin-username $ADMIN_USER --admin-password $ADMIN_PASSWORD --authentication-type password --public-ip-sku Standard --nsg-rule SSH --output table
    if ($LASTEXITCODE -ne 0) { throw "Control Plane VM creation failed" }

    # 4. Create Worker 01 - B1s
    az vm create --resource-group $RG --name worker01 --location $LOCATION --image Ubuntu2404 --size Standard_B1s --vnet-name $VNET --subnet $SUBNET --admin-username $ADMIN_USER --admin-password $ADMIN_PASSWORD --authentication-type password --public-ip-sku Standard --nsg-rule SSH --output table
    if ($LASTEXITCODE -ne 0) { throw "Worker01 creation failed" }

    # 5. Create Worker 02 - B1s
    az vm create --resource-group $RG --name worker02 --location $LOCATION --image Ubuntu2404 --size Standard_B1s --vnet-name $VNET --subnet $SUBNET --admin-username $ADMIN_USER --admin-password $ADMIN_PASSWORD --authentication-type password --public-ip-sku Standard --nsg-rule SSH --output table
    if ($LASTEXITCODE -ne 0) { throw "Worker02 creation failed" }

    # 6. Display VM details
    az vm list --resource-group $RG --show-details --output table
    if ($LASTEXITCODE -ne 0) { throw "VM verification failed" }

    # 7. Display IP addresses
    az vm list-ip-addresses --resource-group $RG --output table
    if ($LASTEXITCODE -ne 0) { throw "IP verification failed" }

    Write-Host "`nKubernetes infrastructure created successfully!" -ForegroundColor Green

}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
}
finally {
    $ADMIN_PASSWORD = $null
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
