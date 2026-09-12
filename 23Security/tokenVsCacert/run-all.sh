#!/usr/bin/env bash
#
# Convenience runner: seeds a demo pod, then runs BOTH demos back to back so
# you can compare the two kubeconfigs and their `kubectl auth whoami` output.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="auth-demo"

echo "############################################################"
echo "# Seeding a sample pod so 'get pods' returns something"
echo "############################################################"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl run demo-nginx --image=nginx:alpine -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo; echo "############################################################"
echo "# DEMO 1: TOKEN-BASED (ServiceAccount)"
echo "############################################################"
bash "${HERE}/01-serviceaccount-token/setup.sh"
bash "${HERE}/01-serviceaccount-token/demo.sh"

echo; echo "############################################################"
echo "# DEMO 2: CERTIFICATE-BASED (X.509 client cert)"
echo "############################################################"
bash "${HERE}/02-client-certificate/setup.sh"
bash "${HERE}/02-client-certificate/demo.sh"

echo; echo "############################################################"
echo "# Compare the two generated kubeconfigs:"
echo "#   /tmp/token-user.kubeconfig  -> user has a 'token:'"
echo "#   /tmp/cert-user.kubeconfig   -> user has 'client-certificate-data'"
echo "############################################################"
echo "Run ./cleanup-all.sh when finished."
