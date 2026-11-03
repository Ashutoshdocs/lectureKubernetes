#!/bin/bash
# =====================================================================
# 05-add-new-node.sh   (HA VM after "az login", or laptop / Cloud Shell)  - fully via CLI
#
#   bash 05-add-new-node.sh                                  # worker4 from cluster.env
#   bash 05-add-new-node.sh vm-k8s-worker5 10.0.1.25 worker
#   bash 05-add-new-node.sh vm-k8s-cp4     10.0.1.14 controlplane
#
# Steps (no SSH needed - uses 'az vm run-command'):
#   1. az vm create (password login)
#   2. run ScriptForAllNodes.sh on the new VM
#   3. ask a running control plane for a fresh join command
#   4. run the join on the new VM
#   5. show 'kubectl get nodes'
# =====================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

NAME="${1:-$NEW_NODE_NAME}"
IP="${2:-$NEW_NODE_IP}"
ROLE="${3:-worker}"
[[ "$ROLE" =~ ^(worker|controlplane)$ ]] || { echo "ROLE must be worker or controlplane"; exit 1; }

# sizes: workers 1 vCPU, control planes 2 vCPU (defaults if cluster.env is older)
VM_SIZE="${VM_SIZE:-Standard_B2s}"
WORKER_VM_SIZE="${WORKER_VM_SIZE:-Standard_B1ms}"
if [ "$ROLE" = "controlplane" ]; then SIZE="${VM_SIZE}"; else SIZE="${WORKER_VM_SIZE}"; fi

# ---- quota check (skipped if the VM already exists) ----
if ! az vm show -g "${RG}" -n "${NAME}" -o none 2>/dev/null; then
  NEED=$(az vm list-sizes -l "${LOCATION}" --query "[?name=='${SIZE}'].numberOfCores | [0]" -o tsv | tr -d '\r')
  read -r USED LIMIT < <(az vm list-usage -l "${LOCATION}" \
    --query "[?name.value=='cores'] | [0].[currentValue, limit]" -o tsv | tr -d '\r')
  echo "=== vCPU quota ${LOCATION}: used ${USED}/${LIMIT}, ${NAME} (${SIZE}) needs ${NEED} ==="
  if [ $((USED + NEED)) -gt "${LIMIT}" ]; then
    echo "Not enough quota. Options:"
    echo "  - free a worker:  az vm deallocate -g ${RG} -n vm-k8s-worker3"
    echo "    ('stopped' VMs still use quota - they must be 'deallocated')"
    echo "  - or request Total Regional vCPUs >= $((USED + NEED)) for ${LOCATION}"
    echo "VM power states:"
    az vm list -g "${RG}" -d --query "[].{VM:name, State:powerState, Size:hardwareProfile.vmSize}" -o table
    exit 1
  fi
fi

run_on() {   # $1=vm, $2=script file  -> prints stdout of the script
  az vm run-command invoke -g "${RG}" -n "$1" --command-id RunShellScript \
    --scripts @"$2" --query "value[0].message" -o tsv | tr -d '\r'
}

# pick the first control plane that is running
CP_VM=""
for n in ${CP_NODES}; do
  st=$(az vm get-instance-view -g "${RG}" -n "${n%%:*}" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv | tr -d '\r')
  [ "$st" = "VM running" ] && { CP_VM="${n%%:*}"; break; }
done
[ -n "$CP_VM" ] || { echo "No running control plane found"; exit 1; }
echo "=== Using ${CP_VM} to generate the join command ==="

if ! az vm show -g "${RG}" -n "${NAME}" -o none 2>/dev/null && [ -z "${ADMIN_PASSWORD}" ]; then
  read -rsp "Password for '${ADMIN_USER}' on new VM ${NAME}: " ADMIN_PASSWORD; echo
fi

echo "=== 1/5 Creating VM ${NAME} (${IP}, ${SIZE}) ==="
if az vm show -g "${RG}" -n "${NAME}" -o none 2>/dev/null; then
  echo "    ${NAME} already exists - reusing it"
  az vm start -g "${RG}" -n "${NAME}" -o none
else
  az vm create -g "${RG}" -n "${NAME}" \
    --image "${VM_IMAGE}" --size "${SIZE}" \
    --admin-username "${ADMIN_USER}" --admin-password "${ADMIN_PASSWORD}" \
    --authentication-type password \
    --vnet-name "${VNET_NAME}" --subnet "${SUBNET_NAME}" \
    --private-ip-address "${IP}" --public-ip-sku Standard --nsg "" \
    --os-disk-size-gb 30 --only-show-errors -o table
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== 2/5 Installing prerequisites on ${NAME} (takes a few minutes) ==="
{ echo "#!/bin/bash"
  cat "${SCRIPT_DIR}/cluster.env"
  echo "NEW_NODE_NAME=\"${NAME}\"; NEW_NODE_IP=\"${IP}\""
  sed '1d' "${SCRIPT_DIR}/ScriptForAllNodes.sh"; } > "$TMP/setup.sh"
run_on "${NAME}" "$TMP/setup.sh" | tail -5

echo "=== 3/5 Getting join command from ${CP_VM} ==="
cat > "$TMP/getjoin.sh" <<'EOF'
#!/bin/bash
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "JOIN=$(kubeadm token create --print-join-command --ttl 2h)"
echo "KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | grep -E '^[a-f0-9]{64}$')"
EOF
OUT=$(run_on "${CP_VM}" "$TMP/getjoin.sh")
JOIN=$(echo "$OUT" | grep -oP '^JOIN=\K.*')
KEY=$(echo "$OUT" | grep -oP '^KEY=\K.*')
[ -n "$JOIN" ] || { echo "Could not get join command:"; echo "$OUT"; exit 1; }
echo "    ${JOIN%%--token*}--token ***"

echo "=== 4/5 Joining ${NAME} as ${ROLE} ==="
if [ "$ROLE" = "controlplane" ]; then
  cat > "$TMP/join.sh" <<EOF
#!/bin/bash
${JOIN} --control-plane --certificate-key ${KEY}
mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
H=/home/${ADMIN_USER}; mkdir -p \$H/.kube && cp -f /etc/kubernetes/admin.conf \$H/.kube/config && chown -R ${ADMIN_USER}:${ADMIN_USER} \$H/.kube
EOF
else
  printf '#!/bin/bash\n%s\n' "${JOIN}" > "$TMP/join.sh"
fi
run_on "${NAME}" "$TMP/join.sh" | grep -E 'This node has joined|joined|error|ERROR' || true

echo "=== 5/5 Cluster nodes ==="
echo 'sleep 30; kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide' > "$TMP/nodes.sh"
run_on "${CP_VM}" "$TMP/nodes.sh" | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d'

if [ "$ROLE" = "controlplane" ]; then
  echo ""
  echo "NOTE: ${NAME} is now an etcd member too (4 members -> quorum 3)."
  if [ "$(hostname)" = "${LB_NAME}" ] && [ -f /etc/haproxy/haproxy.cfg ]; then
    if ! grep -q "server ${NAME} " /etc/haproxy/haproxy.cfg; then
      echo "=== Adding ${NAME} to HAProxy on this HA VM ==="
      LAST=$(grep -n '^    server .*:6443 check$' /etc/haproxy/haproxy.cfg | tail -1 | cut -d: -f1)
      sudo sed -i "${LAST}a\    server ${NAME} ${IP}:6443 check" /etc/haproxy/haproxy.cfg
      sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
    fi
  else
    echo "      On ${LB_NAME} add to /etc/haproxy/haproxy.cfg (backend k8s-control-planes):"
    echo "        server ${NAME} ${IP}:6443 check      then: sudo systemctl reload haproxy"
  fi
  echo "      Also add ${NAME}:${IP} to CP_NODES in cluster.env so the demo scripts see it."
