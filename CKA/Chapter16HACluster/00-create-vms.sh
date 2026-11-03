#!/bin/bash
# =====================================================================
# 00-create-vms.sh   (run on your LAPTOP / Azure Cloud Shell with az CLI)
#
#   az login
#   bash 00-create-vms.sh
#
# Creates: resource group, VNet/subnet, NSG (SSH allowed), and 7 Ubuntu VMs
#   1 HA VM (HAProxy + admin box) + 3 control planes + 3 workers,
#   fixed private IPs, PASSWORD login.
# Password: set ADMIN_PASSWORD env var, or you'll be prompted.
#   Azure rule: 12-123 chars, 3 of: lower, upper, digit, special.
# =====================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

command -v az >/dev/null || { echo "Azure CLI (az) not found"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Run 'az login' first"; exit 1; }

if [ -z "${ADMIN_PASSWORD}" ]; then
  read -rsp "Password for '${ADMIN_USER}' on all VMs: " ADMIN_PASSWORD; echo
  read -rsp "Confirm password: " P2; echo
  [ "${ADMIN_PASSWORD}" = "${P2}" ] || { echo "Passwords do not match"; exit 1; }
fi

echo "=== Subscription: $(az account show --query name -o tsv) ==="
echo "=== Resource group ${RG} in ${LOCATION} ==="
az group create -n "${RG}" -l "${LOCATION}" -o none

echo "=== Network: VNet ${VNET_CIDR}, subnet ${SUBNET_CIDR} ==="
az network vnet create -g "${RG}" -n "${VNET_NAME}" \
  --address-prefix "${VNET_CIDR}" \
  --subnet-name "${SUBNET_NAME}" --subnet-prefix "${SUBNET_CIDR}" -o none

echo "=== NSG: allow SSH from ${SSH_SOURCE} (traffic inside VNet is allowed by default) ==="
az network nsg create -g "${RG}" -n "${NSG_NAME}" -o none
az network nsg rule create -g "${RG}" --nsg-name "${NSG_NAME}" -n allow-ssh \
  --priority 1000 --access Allow --protocol Tcp --direction Inbound \
  --source-address-prefixes "${SSH_SOURCE}" --destination-port-ranges 22 -o none
az network vnet subnet update -g "${RG}" --vnet-name "${VNET_NAME}" \
  -n "${SUBNET_NAME}" --network-security-group "${NSG_NAME}" -o none

create_vm() {   # $1=name $2=ip [$3=size]
  echo "  -> creating $1 ($2)"
  az vm create -g "${RG}" -n "$1" \
    --image "${VM_IMAGE}" --size "${3:-$VM_SIZE}" \
    --admin-username "${ADMIN_USER}" --admin-password "${ADMIN_PASSWORD}" \
    --authentication-type password \
    --vnet-name "${VNET_NAME}" --subnet "${SUBNET_NAME}" \
    --private-ip-address "$2" \
    --public-ip-sku Standard --nsg "" \
    --os-disk-size-gb 30 \
    --no-wait -o none
}

echo "=== Creating VMs (in parallel) ==="
create_vm "${LB_NAME}" "${LB_IP}" "${LB_VM_SIZE}"
for n in ${CP_NODES} ${WORKER_NODES}; do
  create_vm "${n%%:*}" "${n##*:}"
done

echo "=== Waiting for all VMs to be created ==="
for n in ${LB_NAME}:${LB_IP} ${CP_NODES} ${WORKER_NODES}; do
  az vm wait -g "${RG}" -n "${n%%:*}" --created
  echo "  ${n%%:*} ready"
done

echo ""
echo "=== VMs ==="
az vm list-ip-addresses -g "${RG}" \
  --query "[].{VM:virtualMachine.name, PrivateIP:virtualMachine.network.privateIpAddresses[0], PublicIP:virtualMachine.network.publicIpAddresses[0].ipAddress}" \
  -o table
echo ""
echo "SSH:  ssh ${ADMIN_USER}@<PublicIP>   (password you entered)"
echo "Next: SSH to ${LB_NAME} first (README PART 2). You run all demo commands from there."
