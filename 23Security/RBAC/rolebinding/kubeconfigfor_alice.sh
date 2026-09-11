#!/bin/bash
mkdir -p /home/alice/.kube
# Define variables for paths and control plane IP
CONTROL_PLANE_IP="172.16.0.4"  # Replace with the actual control plane IP
KUBECONFIG_PATH="/home/alice/.kube/config"
CERT_AUTH_PATH="/etc/kubernetes/pki/ca.crt"
CLIENT_CERT_PATH="/etc/kubernetes/pki/alice.crt"
CLIENT_KEY_PATH="/etc/kubernetes/pki/alice.key"

# Set the Kubernetes cluster configuration
kubectl config set-cluster mycluster \
  --certificate-authority=$CERT_AUTH_PATH \
  --embed-certs=true \
  --server=https://$CONTROL_PLANE_IP:6443 \
  --kubeconfig=$KUBECONFIG_PATH

# Set the credentials for alice (user)
kubectl config set-credentials alice \
  --client-certificate=$CLIENT_CERT_PATH \
  --client-key=$CLIENT_KEY_PATH \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_PATH

# Set the context for alice
kubectl config set-context alice-context \
  --cluster=mycluster \
  --namespace=dev \
  --user=alice \
  --kubeconfig=$KUBECONFIG_PATH

# Switch to the created context
kubectl config use-context alice-context --kubeconfig=$KUBECONFIG_PATH

# Set correct permissions so alice owns her kubeconfig
chown -R alice:alice $KUBECONFIG_PATH

echo "Kubeconfig for alice has been set up successfully."

