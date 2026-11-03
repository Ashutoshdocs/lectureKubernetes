#!/bin/bash
# =====================================================================
# ScriptFormaster.sh
# Run ONLY on MASTER as root (after ScriptForBothNode.sh):
#     sudo bash ScriptFormaster.sh
#
# Output: worker_join.sh is saved in THIS SAME FOLDER (and /root)
#         -> cat it, copy the command, paste on the worker with sudo.
# =====================================================================
set -e

POD_CIDR="192.168.0.0/16"
CALICO_VERSION="${CALICO_VERSION:-v3.29.3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

# Use exactly the kubeadm version that is installed (old version)
K8S_FULL=$(kubeadm version -o short)      # e.g. v1.34.2
echo "=== Initializing control plane with ${K8S_FULL} ==="

cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_FULL}
networking:
  podSubnet: "${POD_CIDR}"
EOF

kubeadm init --config /root/kubeadm-config.yaml | tee /root/kubeadm-init.log

echo "=== Setting kubeconfig (root + sudo user) ==="
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
  USER_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
  mkdir -p "${USER_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
  chown -R "${SUDO_USER}":"${SUDO_USER}" "${USER_HOME}/.kube"
fi
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=== Installing Calico CNI ${CALICO_VERSION} ==="
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml \
    -o /root/calico.yaml
kubectl apply -f /root/calico.yaml

echo "=== Wait for Calico CRDs ==="
kubectl wait --for=condition=Established crd/ippools.crd.projectcalico.org --timeout=120s
sleep 15

echo "=== Replace default IPPool with Azure-safe VXLAN pool ==="
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

echo "=== Generating worker join command (stored in same folder) ==="
JOIN_CMD=$(kubeadm token create --print-join-command --ttl 24h)
cat <<EOF > "${SCRIPT_DIR}/worker_join.sh"
#!/bin/bash
# Paste/run this on the WORKER node as root
sudo ${JOIN_CMD}
EOF
chmod +x "${SCRIPT_DIR}/worker_join.sh"
cp -f "${SCRIPT_DIR}/worker_join.sh" /root/worker_join.sh

echo ""
echo "================================================================="
echo " Master ready (${K8S_FULL}). Join command saved to:"
echo "   ${SCRIPT_DIR}/worker_join.sh"
echo ""
echo " Copy & paste this on the WORKER:"
echo "   sudo ${JOIN_CMD}"
echo "================================================================="
