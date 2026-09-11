#!/bin/bash
# Build a kubeconfig for a user from their already-signed client certificate.
#
# Usage: ./create-kubeconfig.sh <username> [control_plane_ip] [namespace]
set -euo pipefail

USERNAME="${1:?Usage: ./create-kubeconfig.sh <username> [control_plane_ip] [namespace]}"
CONTROL_PLANE_IP="${2:-172.16.0.4}"
NAMESPACE="${3:-dev}"

PKI_DIR="/etc/kubernetes/pki"
KUBE_DIR="/home/${USERNAME}/.kube"
KUBECONFIG_PATH="${KUBE_DIR}/config"

mkdir -p "$KUBE_DIR"

# Cluster entry (embeds the CA so the file is portable)
kubectl config set-cluster mycluster \
  --certificate-authority="${PKI_DIR}/ca.crt" \
  --embed-certs=true \
  --server="https://${CONTROL_PLANE_IP}:6443" \
  --kubeconfig="${KUBECONFIG_PATH}"

# User credentials (embeds the client cert + key)
kubectl config set-credentials "${USERNAME}" \
  --client-certificate="${PKI_DIR}/${USERNAME}.crt" \
  --client-key="${PKI_DIR}/${USERNAME}.key" \
  --embed-certs=true \
  --kubeconfig="${KUBECONFIG_PATH}"

# Context tying user + cluster + default namespace together
kubectl config set-context "${USERNAME}-context" \
  --cluster=mycluster \
  --namespace="${NAMESPACE}" \
  --user="${USERNAME}" \
  --kubeconfig="${KUBECONFIG_PATH}"

kubectl config use-context "${USERNAME}-context" --kubeconfig="${KUBECONFIG_PATH}"

# The Linux user should own their own kubeconfig
chown -R "${USERNAME}:${USERNAME}" "${KUBE_DIR}"

echo "OK: kubeconfig for '${USERNAME}' written to ${KUBECONFIG_PATH} (namespace=${NAMESPACE})"
