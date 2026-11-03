#!/usr/bin/env bash
# Remove everything the demos created (keeps the NFS server + StorageClasses).
#   ./scripts/cleanup.sh          -> delete demo namespace, PV, PriorityClass
#   ./scripts/cleanup.sh --all    -> also remove StorageClass nfs-csi + local-path provisioner
set -euo pipefail

kubectl delete namespace am-demo --ignore-not-found --wait=true
kubectl delete pv rox-website-pv --ignore-not-found      # Retain policy: delete PV object only
kubectl delete priorityclass am-demo-high --ignore-not-found

if [[ "${1:-}" == "--all" ]]; then
  kubectl delete storageclass nfs-csi --ignore-not-found
  kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml --ignore-not-found
  echo "csi-driver-nfs left installed. Remove with:"
  echo "  curl -fsSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.2/deploy/uninstall-driver.sh | bash -s v4.13.2 --"
fi

echo "Done. Content in /srv/nfs/static/website on the NFS server is untouched."
