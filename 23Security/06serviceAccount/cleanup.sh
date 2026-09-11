#!/usr/bin/env bash
#
# Tears down the demo. Deleting the namespace removes every namespaced object
# inside it (pods, ServiceAccount, Role, RoleBinding) in one shot.

set -uo pipefail

NS="practical"

echo "Deleting namespace '$NS' and everything in it..."
kubectl delete namespace "$NS" --ignore-not-found
echo "Done."
