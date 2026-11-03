#!/bin/bash
# =====================================================================
# generate-join.sh   -  run on ANY working control plane as root
#     sudo bash generate-join.sh
#
# Creates fresh join files in this folder (tokens: 24h, cert key: 2h):
#   join_controlplane.sh   join_worker.sh
# Re-run whenever a token / certificate key has expired.
# =====================================================================
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG=/etc/kubernetes/admin.conf

JOIN_CMD=$(kubeadm token create --print-join-command --ttl 24h)
# re-upload control plane certs (encrypted in a Secret, valid 2h) and get the key
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | grep -E '^[a-f0-9]{64}$')

cat <<EOF > "${SCRIPT_DIR}/join_worker.sh"
#!/bin/bash
# Run on a WORKER node as root (after ScriptForAllNodes.sh)
set -e
${JOIN_CMD}
EOF

cat <<EOF > "${SCRIPT_DIR}/join_controlplane.sh"
#!/bin/bash
# Run on an additional CONTROL PLANE node as root (after ScriptForAllNodes.sh)
# Certificate key expires 2h after generation -> re-run generate-join.sh
set -e
${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}

mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
if [ -n "\${SUDO_USER}" ] && [ "\${SUDO_USER}" != "root" ]; then
  H=\$(getent passwd "\${SUDO_USER}" | cut -d: -f6)
  mkdir -p "\$H/.kube" && cp -f /etc/kubernetes/admin.conf "\$H/.kube/config"
  chown -R "\${SUDO_USER}:\${SUDO_USER}" "\$H/.kube"
fi
echo "Control plane joined: \$(hostname)"
EOF
chmod +x "${SCRIPT_DIR}/join_worker.sh" "${SCRIPT_DIR}/join_controlplane.sh"
cp -f "${SCRIPT_DIR}"/join_*.sh /root/

echo ""
echo "================================================================="
echo " Saved: ${SCRIPT_DIR}/join_controlplane.sh   and   join_worker.sh"
echo ""
echo " CONTROL PLANES (cp2, cp3) - paste as root:"
echo "   ${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}"
echo ""
echo " WORKERS - paste as root:"
echo "   ${JOIN_CMD}"
echo "================================================================="
