#!/bin/bash
# =====================================================================
# ScriptForFirstMaster.sh   -  run ONLY on the FIRST control plane (vm-k8s-cp1)
#     sudo bash ScriptForFirstMaster.sh
#
# Needs: ScriptForHAVM.sh already done on the HA VM (HAProxy must be up).
# Output (saved in THIS SAME FOLDER, and /root):
#   join_controlplane.sh  -> paste/run on vm-k8s-cp2 and vm-k8s-cp3
#   join_worker.sh        -> paste/run on the 3 workers
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/cluster.env"

FIRST_CP="${CP_NODES%% *}"
FIRST_NAME="${FIRST_CP%%:*}"; FIRST_IP="${FIRST_CP##*:}"
if [ "$(hostname)" != "${FIRST_NAME}" ]; then
  echo "This must run on ${FIRST_NAME} (this is $(hostname))."; exit 1
fi

echo "=== Checking HA VM endpoint ${API_ENDPOINT_NAME}:${API_ENDPOINT_PORT} ==="
timeout 5 bash -c "</dev/tcp/${LB_IP}/${API_ENDPOINT_PORT}" \
  || { echo "HAProxy on ${LB_NAME} (${LB_IP}:${API_ENDPOINT_PORT}) not reachable. Run ScriptForHAVM.sh there first."; exit 1; }

K8S_FULL=$(kubeadm version -o short)
K8S_MINOR=$(echo "${K8S_FULL}" | cut -d. -f2)
# v1beta4 exists from 1.31; older kubeadm only knows v1beta3
API="kubeadm.k8s.io/v1beta4"; [ "${K8S_MINOR}" -lt 31 ] && API="kubeadm.k8s.io/v1beta3"

SANS="    - ${API_ENDPOINT_NAME}
    - ${LB_NAME}
    - ${LB_IP}
    - 127.0.0.1"
for n in ${CP_NODES}; do SANS="${SANS}
    - ${n%%:*}
    - ${n##*:}"; done

cat <<EOF > /root/kubeadm-config.yaml
apiVersion: ${API}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${FIRST_IP}
  bindPort: 6443
---
apiVersion: ${API}
kind: ClusterConfiguration
kubernetesVersion: ${K8S_FULL}
controlPlaneEndpoint: "${API_ENDPOINT_NAME}:${API_ENDPOINT_PORT}"
apiServer:
  certSANs:
${SANS}
networking:
  podSubnet: "${POD_CIDR}"
EOF
echo "=== kubeadm config ==="; cat /root/kubeadm-config.yaml

echo "=== kubeadm init (HA, ${K8S_FULL}) ==="
kubeadm init --config /root/kubeadm-config.yaml --upload-certs | tee /root/kubeadm-init.log

setup_kubeconfig() {
  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
    local H; H=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
    mkdir -p "$H/.kube" && cp -f /etc/kubernetes/admin.conf "$H/.kube/config"
    chown -R "${SUDO_USER}:${SUDO_USER}" "$H/.kube"
  fi
}
setup_kubeconfig
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=== Calico ${CALICO_VERSION} (VXLAN pool, Azure-safe) ==="
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o /root/calico.yaml
kubectl apply -f /root/calico.yaml
kubectl wait --for=condition=Established crd/ippools.crd.projectcalico.org --timeout=120s
sleep 15
kubectl delete ippools.crd.projectcalico.org default-ipv4-ippool --ignore-not-found=true
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: azure-ippool
spec:
  cidr: ${POD_CIDR}
  vxlanMode: Always
  ipipMode: Never
  natOutgoing: true
  disabled: false
EOF
kubectl rollout restart daemonset/calico-node -n kube-system

echo "=== Bundle for the HA VM (kubeconfig + etcd client certs) ==="
B=$(mktemp -d)
cp /etc/kubernetes/admin.conf "$B/"
cp /etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/healthcheck-client.crt \
   /etc/kubernetes/pki/etcd/healthcheck-client.key "$B/"
grep -oP 'image:.*etcd:\K[0-9.]+' /etc/kubernetes/manifests/etcd.yaml > "$B/etcd-version"
USER_HOME=$(getent passwd "${ADMIN_USER}" | cut -d: -f6)
tar czf "${USER_HOME}/lb-bundle.tgz" -C "$B" .
chown "${ADMIN_USER}:${ADMIN_USER}" "${USER_HOME}/lb-bundle.tgz"
chmod 600 "${USER_HOME}/lb-bundle.tgz"
rm -rf "$B"
echo "Saved ${USER_HOME}/lb-bundle.tgz  -> on ${LB_NAME} run: bash HAVM-GetClusterAccess.sh"

echo "=== Generating join files ==="
bash "${SCRIPT_DIR}/generate-join.sh"
