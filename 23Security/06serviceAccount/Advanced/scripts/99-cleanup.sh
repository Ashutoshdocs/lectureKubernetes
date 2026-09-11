#!/usr/bin/env bash
#
# Removes everything by deleting the namespace.
set -uo pipefail

NS="acme-prod"
echo "Deleting namespace '$NS' and all resources in it..."
kubectl delete namespace "$NS" --ignore-not-found
echo "Done."
