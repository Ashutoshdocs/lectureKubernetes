#!/bin/bash
# Onboard a NEW user into an existing group — the whole point of group binding.
# Notice there is NO kubectl apply of any RBAC file here: the group's
# RoleBinding already grants access to anyone with a cert in that group.
#
# Usage: ./add-user.sh <username> [group] [control_plane_ip]
set -euo pipefail

USERNAME="${1:?Usage: ./add-user.sh <username> [group] [control_plane_ip]}"
GROUP="${2:-dev}"
CONTROL_PLANE_IP="${3:-172.16.0.4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make sure a matching Linux account exists so the kubeconfig has an owner.
if ! id "${USERNAME}" &>/dev/null; then
  echo "Creating Linux user '${USERNAME}'..."
  useradd -m "${USERNAME}"
fi

echo "== 1/2  Issuing certificate (CN=${USERNAME}, O=${GROUP}) =="
bash "${SCRIPT_DIR}/generate-user-cert.sh" "${USERNAME}" "${GROUP}"

echo "== 2/2  Building kubeconfig =="
bash "${SCRIPT_DIR}/create-kubeconfig.sh" "${USERNAME}" "${CONTROL_PLANE_IP}" "${GROUP}"

echo
echo "Done. '${USERNAME}' is now a member of group '${GROUP}' and inherits its RBAC."
echo "No Role or RoleBinding was created or modified."
