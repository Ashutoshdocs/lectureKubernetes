#!/usr/bin/env bash
# Make the locally-built images available to the cluster WITHOUT a registry.
# Pick the block that matches your cluster tool.
set -euo pipefail

IMAGES=("arcade-backend:v1" "arcade-frontend:v1")

# Autodetect the tool; override with:  CLUSTER=kubeadm ./load-images.sh
CLUSTER="${CLUSTER:-auto}"
if [ "$CLUSTER" = "auto" ]; then
  if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
    CLUSTER=minikube
  elif command -v kind >/dev/null 2>&1 && kind get clusters >/dev/null 2>&1; then
    CLUSTER=kind
  else
    CLUSTER=kubeadm
  fi
fi

echo "==> Loading images for: $CLUSTER"

case "$CLUSTER" in
  kubeadm)
    # kubeadm uses containerd. Import into the k8s.io namespace so kubelet finds them.
    for img in "${IMAGES[@]}"; do
      echo "  -> $img"
      docker save "$img" -o "/tmp/${img/:/_}.tar"
      sudo ctr -n k8s.io images import "/tmp/${img/:/_}.tar"
      rm -f "/tmp/${img/:/_}.tar"
    done
    ;;
  minikube)
    for img in "${IMAGES[@]}"; do
      echo "  -> $img"
      minikube image load "$img"
    done
    ;;
  kind)
    for img in "${IMAGES[@]}"; do
      echo "  -> $img"
      kind load docker-image "$img"
    done
    ;;
  *)
    echo "Unknown CLUSTER=$CLUSTER. Use kubeadm|minikube|kind." >&2
    exit 1
    ;;
esac

echo "==> Images loaded."
