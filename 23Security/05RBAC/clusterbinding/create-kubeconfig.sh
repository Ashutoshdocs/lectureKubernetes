#!/bin/bash
# Build a kubeconfig for a user from their signed client certificate.
# Because access is cluster-wide, the context's default namespace is just a
# convenience — the user can query any namespace (or use -A for all).
#
# Usage: ./create-kubeconfig.sh <username> [control_plane_ip] [default_namespace]
set -euo pipefail

USERNAME="${1:?Usage: ./create-kubeconfig.sh <username> [control_plane_ip] [default_namespace]}"
CONTROL_PLANE_IP="${2:-172.16.0.4}"
NAMESPACE="${3:-default}"

PKI_DIR="/etc/kubernetes/pki"
KUBE_DIR="/home/${USERNAME}/.kube"
KUBECONFIG_PATH="${KUBE_DIR}/config"

mkdir -p "$KUBE_DIR"

kubectl config set-cluster mycluster \
  --certificate-authority="${PKI_DIR}/ca.crt" \
  --embed-certs=true \
  --server="https://${CONTROL_PLANE_IP}:6443" \
  --kubeconfig="${KUBECONFIG_PATH}"

kubectl config set-credentials "${USERNAME}" \
  --client-certificate="${PKI_DIR}/${USERNAME}.crt" \
  --client-key="${PKI_DIR}/${USERNAME}.key" \
  --embed-certs=true \
  --kubeconfig="${KUBECONFIG_PATH}"

kubectl config set-context "${USERNAME}-context" \
  --cluster=mycluster \
  --namespace="${NAMESPACE}" \
  --user="${USERNAME}" \
  --kubeconfig="${KUBECONFIG_PATH}"

kubectl config use-context "${USERNAME}-context" --kubeconfig="${KUBECONFIG_PATH}"

chown -R "${USERNAME}:${USERNAME}" "${KUBE_DIR}"

echo "OK: kubeconfig for '${USERNAME}' written to ${KUBECONFIG_PATH}"
