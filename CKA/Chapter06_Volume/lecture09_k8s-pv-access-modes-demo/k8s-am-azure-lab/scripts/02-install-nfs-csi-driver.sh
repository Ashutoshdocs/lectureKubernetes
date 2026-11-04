#!/bin/bash
# ============================================================
# Run on k8s-control-plane as azureuser (needs kubectl):
#   bash scripts/02-install-nfs-csi-driver.sh
#
# Installs the NFS CSI driver (nfs.csi.k8s.io).
# Only the ReadWriteOncePod demo needs it: RWOP works with CSI
# volumes only, not with the built-in "nfs:" volume type.
# ============================================================
set -euo pipefail

CSI_NFS_VERSION="v4.13.2"

curl -fsSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${CSI_NFS_VERSION}/deploy/install-driver.sh" \
  | bash -s "${CSI_NFS_VERSION}" --

kubectl -n kube-system rollout status deployment/csi-nfs-controller --timeout=300s
kubectl -n kube-system rollout status daemonset/csi-nfs-node        --timeout=300s

kubectl get csidrivers
echo "NFS CSI driver ready."
