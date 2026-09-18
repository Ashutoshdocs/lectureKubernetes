#!/usr/bin/env bash
# ============================================================================
# 04 - AZURE KEY VAULT  --  one-shot setup script
# ============================================================================
# Creates the Key Vault, stores the SQL password, enables the CSI driver +
# Workload Identity on AKS, and federates a managed identity to the pod's
# ServiceAccount. Edit the variables at the top, then run:  bash setup-azure.sh
#
# Prereqs: az CLI (logged in), kubectl pointed at your AKS cluster, helm.
# ============================================================================
set -euo pipefail

# ---- EDIT THESE ------------------------------------------------------------
RG="rg-k8s-secret-demo"           # resource group
LOCATION="eastus"
AKS="aks-secret-demo"             # existing AKS cluster name
KV="kv-secret-demo-$RANDOM"       # Key Vault names are globally unique
IDENTITY="id-sql-secret"          # user-assigned managed identity
NAMESPACE="default"
SA_NAME="workload-identity-sa"
SECRET_NAME="sql-password"        # name of the secret INSIDE Key Vault
SECRET_VALUE="P@ssw0rd-VERY-INSECURE-123"
# ---------------------------------------------------------------------------

echo ">> 1. Create Key Vault and store the password"
az keyvault create -n "$KV" -g "$RG" -l "$LOCATION" --enable-rbac-authorization true
az keyvault secret set --vault-name "$KV" -n "$SECRET_NAME" --value "$SECRET_VALUE"

echo ">> 2. Enable the Secrets Store CSI Driver + Workload Identity on AKS"
az aks enable-addons --addons azure-keyvault-secrets-provider -g "$RG" -n "$AKS"
az aks update -g "$RG" -n "$AKS" --enable-oidc-issuer --enable-workload-identity

OIDC_ISSUER="$(az aks show -g "$RG" -n "$AKS" --query oidcIssuerProfile.issuerUrl -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo ">> 3. Create a user-assigned managed identity and grant it Key Vault access"
az identity create -g "$RG" -n "$IDENTITY"
CLIENT_ID="$(az identity show -g "$RG" -n "$IDENTITY" --query clientId -o tsv)"
KV_ID="$(az keyvault show -n "$KV" --query id -o tsv)"
az role assignment create \
  --assignee "$CLIENT_ID" \
  --role "Key Vault Secrets User" \
  --scope "$KV_ID"

echo ">> 4. Federate the identity to the Kubernetes ServiceAccount"
az identity federated-credential create \
  --name "fc-sql-secret" \
  -g "$RG" \
  --identity-name "$IDENTITY" \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:${NAMESPACE}:${SA_NAME}" \
  --audience "api://AzureADTokenExchange"

echo ""
echo "=============================================================="
echo " DONE. Put these values into secretproviderclass.yaml and the"
echo " ServiceAccount annotation in sql-deployment.yaml:"
echo "   clientID   / azure.workload.identity/client-id : $CLIENT_ID"
echo "   keyvaultName                                   : $KV"
echo "   tenantId                                       : $TENANT_ID"
echo "   objectName (secret in Key Vault)               : $SECRET_NAME"
echo "=============================================================="
