#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# AKS + kubectl + Helm + grpcurl Setup
# ============================================================
#
# Purpose:
#   1. Connect Azure CLI to an AKS cluster
#   2. Download kubectl into THIS DIRECTORY
#   3. Download Helm into THIS DIRECTORY
#   4. Download grpcurl into THIS DIRECTORY
#   5. Configure AKS kubeconfig
#   6. Run all verification commands using local binaries
#
# Usage:
#   chmod +x setup-aks-gateway-tools.sh
#   ./setup-aks-gateway-tools.sh
#
# Optional environment variables:
#   RESOURCE_GROUP=my-rg AKS_CLUSTER=my-aks ./setup-aks-gateway-tools.sh
#
# If variables are not supplied, the script asks for them.
#
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECTL="$SCRIPT_DIR/kubectl"
HELM="$SCRIPT_DIR/helm"
GRPCURL="$SCRIPT_DIR/grpcurl"

echo
echo "============================================================"
echo " AKS + Gateway API Tool Setup"
echo "============================================================"
echo "Working directory: $SCRIPT_DIR"
echo

# ------------------------------------------------------------
# 1. Check required base commands
# ------------------------------------------------------------

for cmd in az curl tar unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required but was not found."
        echo
        echo "Ubuntu installation:"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y curl tar unzip"
        echo
        echo "Install Azure CLI from:"
        echo "  https://learn.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi
done

# ------------------------------------------------------------
# 2. Azure login
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 1 - Azure Login"
echo "============================================================"

if ! az account show >/dev/null 2>&1; then
    echo "Azure CLI is not logged in."
    az login
else
    echo "Already logged in to Azure."
fi

echo
echo "Current Azure account:"
az account show --query "{Subscription:name,SubscriptionId:id,Tenant:tenantId}" -o table

# ------------------------------------------------------------
# 3. Ask for AKS details
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 2 - AKS Cluster Details"
echo "============================================================"

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
AKS_CLUSTER="${AKS_CLUSTER:-}"

if [[ -z "$RESOURCE_GROUP" ]]; then
    read -r -p "Enter AKS Resource Group: " RESOURCE_GROUP
fi

if [[ -z "$AKS_CLUSTER" ]]; then
    read -r -p "Enter AKS Cluster Name: " AKS_CLUSTER
fi

echo
echo "Resource Group : $RESOURCE_GROUP"
echo "AKS Cluster    : $AKS_CLUSTER"

# ------------------------------------------------------------
# 4. Verify AKS cluster
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 3 - Verify AKS Cluster"
echo "============================================================"

az aks show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER" \
    --query "{Name:name,Location:location,KubernetesVersion:kubernetesVersion,ProvisioningState:provisioningState}" \
    -o table

# ------------------------------------------------------------
# 5. Download kubectl into this directory
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 4 - Download kubectl"
echo "============================================================"

KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"

echo "Latest stable kubectl: $KUBECTL_VERSION"

if [[ ! -x "$KUBECTL" ]]; then
    echo "Downloading kubectl..."
    curl -L \
        -o "$KUBECTL" \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    chmod +x "$KUBECTL"
else
    echo "kubectl already exists in this directory."
fi

echo
"$KUBECTL" version --client

# ------------------------------------------------------------
# 6. Download Helm into this directory
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 5 - Download Helm"
echo "============================================================"

HELM_VERSION="$(curl -L -s https://get.helm.sh/helm-latest-version)"

echo "Latest Helm version: $HELM_VERSION"

if [[ ! -x "$HELM" ]]; then

    HELM_TARBALL="$SCRIPT_DIR/helm.tar.gz"

    echo "Downloading Helm..."

    curl -L \
        -o "$HELM_TARBALL" \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"

    tar -xzf "$HELM_TARBALL" -C "$SCRIPT_DIR"

    cp "$SCRIPT_DIR/linux-amd64/helm" "$HELM"

    chmod +x "$HELM"

    rm -rf "$SCRIPT_DIR/linux-amd64"
    rm -f "$HELM_TARBALL"

else
    echo "helm already exists in this directory."
fi

echo
"$HELM" version

# ------------------------------------------------------------
# 7. Download grpcurl into this directory
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 6 - Download grpcurl"
echo "============================================================"

# Determine latest grpcurl release from GitHub.
GRPCURL_VERSION="$(
    curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/fullstorydev/grpcurl/releases/latest |
    grep '"tag_name":' |
    head -1 |
    cut -d '"' -f 4
)"

if [[ -z "$GRPCURL_VERSION" ]]; then
    echo "ERROR: Could not determine grpcurl version."
    exit 1
fi

echo "Latest grpcurl version: $GRPCURL_VERSION"

if [[ ! -x "$GRPCURL" ]]; then

    GRPCURL_TARBALL="$SCRIPT_DIR/grpcurl.tar.gz"

    echo "Downloading grpcurl..."

    curl -L \
        -o "$GRPCURL_TARBALL" \
        "https://github.com/fullstorydev/grpcurl/releases/download/${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION#v}_linux_x86_64.tar.gz"

    tar -xzf "$GRPCURL_TARBALL" \
        -C "$SCRIPT_DIR" \
        grpcurl

    chmod +x "$GRPCURL"

    rm -f "$GRPCURL_TARBALL"

else
    echo "grpcurl already exists in this directory."
fi

echo
"$GRPCURL" --version

# ------------------------------------------------------------
# 8. Configure AKS kubeconfig
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 7 - Download AKS kubeconfig"
echo "============================================================"

echo "Getting AKS credentials..."

az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER" \
    --overwrite-existing

echo
echo "Kubeconfig successfully configured."

# ------------------------------------------------------------
# 9. Verify AKS using kubectl from THIS directory
# ------------------------------------------------------------

echo
echo "============================================================"
echo " STEP 8 - Verify AKS"
echo "============================================================"

echo
echo "kubectl client:"
"$KUBECTL" version --client

echo
echo "AKS nodes:"
"$KUBECTL" get nodes -o wide

echo
echo "Cluster information:"
"$KUBECTL" cluster-info

# ------------------------------------------------------------
# 10. Create a local helper environment file
# ------------------------------------------------------------

cat > "$SCRIPT_DIR/env.sh" <<EOF
#!/usr/bin/env bash

export AKS_RESOURCE_GROUP="$RESOURCE_GROUP"
export AKS_CLUSTER="$AKS_CLUSTER"

export KUBECTL="$SCRIPT_DIR/kubectl"
export HELM="$SCRIPT_DIR/helm"
export GRPCURL="$SCRIPT_DIR/grpcurl"

export PATH="$SCRIPT_DIR:\$PATH"
EOF

chmod +x "$SCRIPT_DIR/env.sh"

# ------------------------------------------------------------
# 11. Create convenient wrapper commands
# ------------------------------------------------------------

cat > "$SCRIPT_DIR/kubectl-local" <<EOF
#!/usr/bin/env bash
exec "$KUBECTL" "\$@"
EOF

cat > "$SCRIPT_DIR/helm-local" <<EOF
#!/usr/bin/env bash
exec "$HELM" "\$@"
EOF

cat > "$SCRIPT_DIR/grpcurl-local" <<EOF
#!/usr/bin/env bash
exec "$GRPCURL" "\$@"
EOF

chmod +x \
    "$SCRIPT_DIR/kubectl-local" \
    "$SCRIPT_DIR/helm-local" \
    "$SCRIPT_DIR/grpcurl-local"

# ------------------------------------------------------------
# 12. Final verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo " FINAL VERIFICATION"
echo "============================================================"

echo
echo "1. kubectl:"
"$KUBECTL" version --client

echo
echo "2. helm:"
"$HELM" version

echo
echo "3. grpcurl:"
"$GRPCURL" --version

echo
echo "4. AKS nodes:"
"$KUBECTL" get nodes

echo
echo "5. Current context:"
"$KUBECTL" config current-context

echo
echo "6. Contexts:"
"$KUBECTL" config get-contexts

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"

echo
echo "All tools are stored in:"
echo "  $SCRIPT_DIR"

echo
echo "Files:"
echo "  $SCRIPT_DIR/kubectl"
echo "  $SCRIPT_DIR/helm"
echo "  $SCRIPT_DIR/grpcurl"
echo "  $SCRIPT_DIR/env.sh"
echo "  $SCRIPT_DIR/kubectl-local"
echo "  $SCRIPT_DIR/helm-local"
echo "  $SCRIPT_DIR/grpcurl-local"

echo
echo "For future sessions run:"
echo
echo "  cd \"$SCRIPT_DIR\""
echo "  source ./env.sh"
echo
echo "Then:"
echo
echo "  ./kubectl get nodes"
echo "  ./helm version"
echo "  ./grpcurl --version"
echo

echo "============================================================"
