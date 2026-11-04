# ============================================================
# Azure Kubernetes Access Modes Lab  (RWO / ROX / RWX / RWOP)
# 4 VMs:
#   NFS VM          = 10.0.1.4   (dedicated NFS server)
#   Control Plane   = 10.0.1.5   (kubeadm control plane)
#   Worker 1        = 10.0.1.6   (kubeadm worker)
#   Worker 2        = 10.0.1.7   (kubeadm worker)
#
# Each VM is created with cloud-init (custom-data) so that:
#   - nfs-vm          : NFS server installed, /srv/nfs/k8s/{rwo,rox,rwx,rwop}
#                       exported, ROX content pre-populated
#   - k8s-* (3 VMs)   : containerd + kubeadm/kubelet/kubectl + nfs-common
#                       installed, swap off, kernel modules + sysctls set,
#                       /mnt/disks/rwo created for the local (RWO) volume
#
# Requirements: Azure CLI logged in (az login), PowerShell 5.1+ or 7+
# Usage:        .\create-lab-vms.ps1
# ============================================================

$RG         = "rg-k8s-access-modes"
$LOCATION   = "centralindia"

$VNET       = "vnet-k8s"
$SUBNET     = "subnet-k8s"
$NSG        = "nsg-k8s"

$NFS_VM     = "nfs-vm"
$CP_VM      = "k8s-control-plane"
$W1_VM      = "k8s-worker-1"
$W2_VM      = "k8s-worker-2"

$NFS_IP     = "10.0.1.4"
$CP_IP      = "10.0.1.5"
$W1_IP      = "10.0.1.6"
$W2_IP      = "10.0.1.7"

$NFS_SIZE   = "Standard_B1s"   # 1 vCPU / 1 GB is plenty for NFS
$K8S_SIZE   = "Standard_B2s"   # kubeadm needs >= 2 vCPU
$IMAGE      = "Ubuntu2204"

$K8S_MINOR  = "v1.35"          # Kubernetes package repo version (pkgs.k8s.io)
$ADMIN_USER = "azureuser"

# Who may SSH in. "*" = anywhere (lab only). Better: your public IP, e.g. "49.36.12.34/32"
$SSH_SOURCE = "*"

# ------------------------------------------------------------
# Pre-checks
# ------------------------------------------------------------

az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to Azure. Run 'az login' first." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Ask for VM password
# (Azure rule: 12-72 chars, 3 of: lower, upper, digit, special)
# ------------------------------------------------------------

$PASSWORD       = Read-Host "Enter password for all VMs" -AsSecureString
$PLAIN_PASSWORD = [System.Net.NetworkCredential]::new("", $PASSWORD).Password

Write-Host ""
Write-Host "============================================================"
Write-Host " Creating Azure Kubernetes Access Modes Lab (4 VMs)"
Write-Host "============================================================"

# ------------------------------------------------------------
# cloud-init scripts (written to temp files, LF line endings, no BOM)
# ------------------------------------------------------------

function Write-LfFile([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$NFS_CLOUD_INIT = @'
#!/bin/bash
# ---------- nfs-vm bootstrap ----------
set -euxo pipefail
exec > /var/log/lab-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nfs-kernel-server

# One sub-directory per demo
mkdir -p /srv/nfs/k8s/rwo /srv/nfs/k8s/rox /srv/nfs/k8s/rwx /srv/nfs/k8s/rwop

# Pre-populated content for the ReadOnlyMany demo
cat > /srv/nfs/k8s/rox/index.html <<'EOF'
<!doctype html>
<html><body style="font-family:sans-serif">
  <h1>Hello from a ReadOnlyMany volume</h1>
  <p>This file lives on nfs-vm at /srv/nfs/k8s/rox.</p>
  <p>Every nginx pod on every worker mounts it read-only.</p>
</body></html>
EOF
echo "Published by the platform team. Pods may read me but never change me." > /srv/nfs/k8s/rox/about.txt

chown -R nobody:nogroup /srv/nfs/k8s
chmod 777 /srv/nfs/k8s/rwo /srv/nfs/k8s/rwx /srv/nfs/k8s/rwop
chmod 755 /srv/nfs/k8s/rox
chmod 644 /srv/nfs/k8s/rox/*

# Export to the whole lab subnet
cat > /etc/exports <<'EOF'
/srv/nfs/k8s 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

systemctl enable --now nfs-kernel-server
exportfs -rav

echo "NFS-VM SETUP COMPLETE"
'@

$K8S_CLOUD_INIT = @'
#!/bin/bash
# ---------- kubernetes node bootstrap (control plane + workers) ----------
set -euxo pipefail
exec > /var/log/lab-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive
K8S_MINOR="__K8S_MINOR__"

# 1. Swap off (kubelet requirement)
swapoff -a || true
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# 2. Kernel modules + sysctls
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 3. containerd (systemd cgroups)
apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gpg nfs-common
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

# 4. kubeadm / kubelet / kubectl
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# 5. Directory for the node-local RWO volume (used on k8s-worker-1)
mkdir -p /mnt/disks/rwo
chmod 777 /mnt/disks/rwo

echo "K8S-NODE SETUP COMPLETE"
'@

$K8S_CLOUD_INIT = $K8S_CLOUD_INIT.Replace("__K8S_MINOR__", $K8S_MINOR)

$TMP          = [System.IO.Path]::GetTempPath()
$NFS_INIT_FILE = Join-Path $TMP "lab-nfs-cloud-init.sh"
$K8S_INIT_FILE = Join-Path $TMP "lab-k8s-cloud-init.sh"
Write-LfFile $NFS_INIT_FILE $NFS_CLOUD_INIT
Write-LfFile $K8S_INIT_FILE $K8S_CLOUD_INIT

# ------------------------------------------------------------
# 1. Create Resource Group
# ------------------------------------------------------------

Write-Host "[1/8] Creating Resource Group $RG in $LOCATION..."

az group create `
    --name $RG `
    --location $LOCATION `
    --output none

# ------------------------------------------------------------
# 2. Create VNet + Subnet
# ------------------------------------------------------------

Write-Host "[2/8] Creating VNet 10.0.0.0/16 and Subnet 10.0.1.0/24..."

az network vnet create `
    --resource-group $RG `
    --name $VNET `
    --location $LOCATION `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $SUBNET `
    --subnet-prefix 10.0.1.0/24 `
    --output none

# ------------------------------------------------------------
# 3. Create NSG + SSH rule
#    (VM-to-VM traffic inside the VNet, including NFS 2049 and the
#     Kubernetes ports, is already allowed by the default
#     AllowVnetInBound rule. Nothing else is opened to the Internet.)
# ------------------------------------------------------------

Write-Host "[3/8] Creating Network Security Group..."

az network nsg create `
    --resource-group $RG `
    --name $NSG `
    --location $LOCATION `
    --output none

Write-Host "      Allowing SSH on port 22 from $SSH_SOURCE..."

az network nsg rule create `
    --resource-group $RG `
    --nsg-name $NSG `
    --name Allow-SSH `
    --priority 100 `
    --access Allow `
    --protocol Tcp `
    --direction Inbound `
    --source-address-prefixes $SSH_SOURCE `
    --destination-port-ranges 22 `
    --output none

# ------------------------------------------------------------
# 4-7. Create the VMs
# ------------------------------------------------------------

function New-LabVm([string]$Step, [string]$Name, [string]$Ip, [string]$Size, [string]$InitFile, [string]$Role) {
    Write-Host "[$Step] Creating $Role ($Name)..."
    Write-Host "      Private IP: $Ip   Size: $Size"

    az vm create `
        --resource-group $RG `
        --name $Name `
        --location $LOCATION `
        --image $IMAGE `
        --size $Size `
        --admin-username $ADMIN_USER `
        --admin-password $PLAIN_PASSWORD `
        --authentication-type password `
        --vnet-name $VNET `
        --subnet $SUBNET `
        --private-ip-address $Ip `
        --nsg $NSG `
        --public-ip-sku Standard `
        --custom-data $InitFile `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create $Name. Check quota / size availability in $LOCATION." -ForegroundColor Red
        exit 1
    }
}

New-LabVm "4/8" $NFS_VM $NFS_IP $NFS_SIZE $NFS_INIT_FILE "NFS Server VM"
New-LabVm "5/8" $CP_VM  $CP_IP  $K8S_SIZE $K8S_INIT_FILE "Kubernetes Control Plane"
New-LabVm "6/8" $W1_VM  $W1_IP  $K8S_SIZE $K8S_INIT_FILE "Kubernetes Worker 1"
New-LabVm "7/8" $W2_VM  $W2_IP  $K8S_SIZE $K8S_INIT_FILE "Kubernetes Worker 2"

Remove-Item $NFS_INIT_FILE, $K8S_INIT_FILE -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# 8. Wait for cloud-init to finish on every VM
# ------------------------------------------------------------

Write-Host "[8/8] Waiting for cloud-init to finish on each VM (3-6 minutes)..."

foreach ($vm in @($NFS_VM, $CP_VM, $W1_VM, $W2_VM)) {
    Write-Host "      $vm ..." -NoNewline
    $out = az vm run-command invoke `
        --resource-group $RG `
        --name $vm `
        --command-id RunShellScript `
        --scripts "cloud-init status --wait >/dev/null; tail -n 1 /var/log/lab-setup.log" `
        --query "value[0].message" `
        --output tsv
    if ($out -match "SETUP COMPLETE") {
        Write-Host " ready" -ForegroundColor Green
    } else {
        Write-Host " CHECK /var/log/lab-setup.log on this VM" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# Display VM IP Information
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host " VM IP INFORMATION"
Write-Host "============================================================"

az vm list-ip-addresses `
    --resource-group $RG `
    --output table

Write-Host ""
Write-Host "============================================================"
Write-Host " LAB CREATED SUCCESSFULLY"
Write-Host "============================================================"
Write-Host ""
Write-Host "NFS VM          $NFS_VM            $NFS_IP"
Write-Host "Control Plane   $CP_VM  $CP_IP"
Write-Host "Worker 1        $W1_VM       $W1_IP"
Write-Host "Worker 2        $W2_VM       $W2_IP"
Write-Host ""
Write-Host "Username    : $ADMIN_USER"
Write-Host "Password    : <the password you entered>"
Write-Host ""
Write-Host "============================================================"
Write-Host " NEXT STEPS (see README.md section 11)"
Write-Host "============================================================"
Write-Host ""
Write-Host "1. Copy the lab folder to the control plane:"
Write-Host "     scp -r . ${ADMIN_USER}@<control-plane-public-ip>:~/k8s-am-lab"
Write-Host "2. On the control plane:"
Write-Host "     cd ~/k8s-am-lab && sudo bash scripts/01-init-control-plane.sh"
Write-Host "3. Run the printed 'kubeadm join' command with sudo on both workers"
Write-Host ""
Write-Host "SSH:"
Write-Host "  az vm ssh -g $RG -n $CP_VM      (or ssh ${ADMIN_USER}@<public-ip>)"
Write-Host "Delete everything when done:"
Write-Host "  .\delete-lab.ps1"
Write-Host "============================================================"
