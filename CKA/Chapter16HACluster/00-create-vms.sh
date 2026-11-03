#!/bin/bash
# =====================================================================
# create-vms.sh  -  HA Kubernetes demo VMs on Azure (from scratch)
#
#   az login
#   bash create-vms.sh
#
# Creates 7 Ubuntu 22.04 VMs, password login, fixed private IPs:
#   vm-k8s-lb        10.0.1.10   1 vCPU  (HA VM: HAProxy + admin box)
#   vm-k8s-cp1..3    10.0.1.11-13 2 vCPU (control planes, kubeadm needs 2)
#   vm-k8s-worker1..3 10.0.1.21-23 1 vCPU (workers)
#   Total = 10 vCPUs
#
# If the resource group already exists, it asks to delete it first.
# Works in Git Bash (Windows), Linux, macOS and Azure Cloud Shell.
# =====================================================================
set -e

# ---------------- settings (same values as cluster.env) ----------------
RG="rg-k8s-ha-demo"
LOCATION="centralindia"
VNET_NAME="vnet-k8s-ha";  VNET_CIDR="10.0.0.0/16"
SUBNET_NAME="snet-k8s";   SUBNET_CIDR="10.0.1.0/24"
NSG_NAME="nsg-k8s-ha"
VM_IMAGE="Ubuntu2204"
ADMIN_USER="azureuser"
SSH_SOURCE="*"                 # tighten to "<your-public-ip>/32" if you can

CP_SIZE="Standard_B2s"         # 2 vCPU / 4 GB
SMALL_SIZE="Standard_B1ms"     # 1 vCPU / 2 GB  (HA VM + workers)

#      name              private-ip   size
VMS="vm-k8s-lb:10.0.1.10:${SMALL_SIZE}
vm-k8s-cp1:10.0.1.11:${CP_SIZE}
vm-k8s-cp2:10.0.1.12:${CP_SIZE}
vm-k8s-cp3:10.0.1.13:${CP_SIZE}
vm-k8s-worker1:10.0.1.21:${SMALL_SIZE}
vm-k8s-worker2:10.0.1.22:${SMALL_SIZE}
vm-k8s-worker3:10.0.1.23:${SMALL_SIZE}"
# ------------------------------------------------------------------------

tsv() { tr -d '\r'; }    # strip Windows CR from az output (Git Bash)

command -v az >/dev/null || { echo "Azure CLI (az) not found"; exit 1; }
az account show -o none 2>/dev/null || { echo "Run 'az login' first"; exit 1; }
echo "=== Subscription: $(az account show --query name -o tsv | tsv) ==="

# ---- start from scratch: remove old resource group ----
if [ "$(az group exists -n "${RG}" | tsv)" = "true" ]; then
  echo "Resource group '${RG}' already exists."
  read -rp "Delete it and ALL its VMs to start fresh? (yes/no): " ans
  [ "$ans" = "yes" ] || { echo "Cancelled."; exit 1; }
  echo "=== Deleting ${RG} (takes a few minutes) ==="
  az group delete -n "${RG}" --yes
fi

# ---- quota check: total regional vCPUs ----
cores_of() { az vm list-sizes -l "${LOCATION}" --query "[?name=='$1'].numberOfCores | [0]" -o tsv | tsv; }
CP_CORES=$(cores_of "${CP_SIZE}"); SMALL_CORES=$(cores_of "${SMALL_SIZE}")
NEED=0
while IFS=: read -r name ip size; do
  [ "$size" = "${CP_SIZE}" ] && NEED=$((NEED + CP_CORES)) || NEED=$((NEED + SMALL_CORES))
done <<< "${VMS}"
read -r USED LIMIT < <(az vm list-usage -l "${LOCATION}" \
  --query "[?name.value=='cores'] | [0].[currentValue, limit]" -o tsv | tsv)
echo "=== vCPU quota ${LOCATION}: used ${USED}/${LIMIT}, need ${NEED} ==="
if [ $((USED + NEED)) -gt "${LIMIT}" ]; then
  echo "Not enough quota: need $((USED + NEED)), limit ${LIMIT}."
  echo "Request more 'Total Regional vCPUs' (Portal -> Subscriptions -> Usage + quotas),"
  echo "or delete/deallocate other VMs in ${LOCATION}."
  exit 1
fi

# ---- password ----
if [ -z "${ADMIN_PASSWORD}" ]; then
  echo "Password rules: 12-123 chars, 3 of: lowercase, uppercase, digit, special."
  read -rsp "Password for '${ADMIN_USER}' on all VMs: " ADMIN_PASSWORD; echo
  read -rsp "Confirm password: " P2; echo
  [ "${ADMIN_PASSWORD}" = "${P2}" ] || { echo "Passwords do not match"; exit 1; }
fi

# ---- network ----
echo "=== Resource group ${RG} (${LOCATION}) ==="
az group create -n "${RG}" -l "${LOCATION}" -o none

echo "=== VNet ${VNET_CIDR} / subnet ${SUBNET_CIDR} ==="
az network vnet create -g "${RG}" -n "${VNET_NAME}" \
  --address-prefix "${VNET_CIDR}" \
  --subnet-name "${SUBNET_NAME}" --subnet-prefix "${SUBNET_CIDR}" -o none

echo "=== NSG: SSH from ${SSH_SOURCE}; all traffic inside the VNet allowed ==="
az network nsg create -g "${RG}" -n "${NSG_NAME}" -o none
az network nsg rule create -g "${RG}" --nsg-name "${NSG_NAME}" -n allow-ssh \
  --priority 1000 --access Allow --protocol Tcp --direction Inbound \
  --source-address-prefixes "${SSH_SOURCE}" --destination-port-ranges 22 -o none
az network vnet subnet update -g "${RG}" --vnet-name "${VNET_NAME}" \
  -n "${SUBNET_NAME}" --network-security-group "${NSG_NAME}" -o none

# ---- VMs (submitted in parallel) ----
echo "=== Creating 7 VMs ==="
while IFS=: read -r name ip size; do
  echo "  -> ${name}  ${ip}  ${size}"
  az vm create -g "${RG}" -n "${name}" \
    --image "${VM_IMAGE}" --size "${size}" \
    --admin-username "${ADMIN_USER}" --admin-password "${ADMIN_PASSWORD}" \
    --authentication-type password \
    --vnet-name "${VNET_NAME}" --subnet "${SUBNET_NAME}" \
    --private-ip-address "${ip}" \
    --public-ip-sku Standard --nsg "" \
    --os-disk-size-gb 30 \
    --only-show-errors --no-wait -o none < /dev/null
done <<< "${VMS}"

echo "=== Waiting for all VMs ==="
FAILED=""
while IFS=: read -r name ip size; do
  if az vm wait -g "${RG}" -n "${name}" --created --timeout 900 < /dev/null 2>/dev/null; then
    echo "  ${name} ready"
  else
    echo "  ${name} FAILED"; FAILED="${FAILED} ${name}"
  fi
done <<< "${VMS}"

echo ""
az vm list -g "${RG}" -d \
  --query "sort_by([].{VM:name, Size:hardwareProfile.vmSize, PrivateIP:privateIps, PublicIP:publicIps, State:powerState}, &PrivateIP)" \
  -o table
echo ""
if [ -n "${FAILED}" ]; then
  echo "Some VMs failed:${FAILED}"
  echo "Details: az vm show -g ${RG} -n <name> --query provisioningState"
  exit 1
fi
echo "Done. SSH: ssh ${ADMIN_USER}@<PublicIP of vm-k8s-lb>   (your password)"
echo "Next: on vm-k8s-lb run 'sudo bash ScriptForHAVM.sh' (README PART 2)."
echo "Delete everything later: az group delete -n ${RG} --yes --no-wait"
