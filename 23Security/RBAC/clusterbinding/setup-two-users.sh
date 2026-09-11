#!/bin/bash
# Onboard the two users named in the ClusterRoleBinding (carol and dave).
# Edit the USERS list if you renamed the subjects in 02-clusterrolebinding-viewers.yml.
#
# Usage: ./setup-two-users.sh [control_plane_ip]
set -euo pipefail

CONTROL_PLANE_IP="${1:-172.16.0.4}"
USERS=("carol" "dave")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for u in "${USERS[@]}"; do
  echo "==================  onboarding ${u}  =================="
  if ! id "${u}" &>/dev/null; then
    echo "Creating Linux user '${u}'..."
    useradd -m "${u}"
  fi
  bash "${SCRIPT_DIR}/generate-user-cert.sh" "${u}"
  bash "${SCRIPT_DIR}/create-kubeconfig.sh" "${u}" "${CONTROL_PLANE_IP}"
  echo
done

echo "Both users onboarded. They are bound cluster-wide by the single"
echo "ClusterRoleBinding 'cluster-pod-viewers-binding'."
