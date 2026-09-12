#!/usr/bin/env bash
#
# Demo 1 — TOKEN-BASED AUTHENTICATION (ServiceAccount bearer tokens)
# ------------------------------------------------------------------
# What this shows:
#   * A ServiceAccount is a *cluster-managed* identity.
#   * The API server hands out a short-lived JWT (JSON Web Token) via the
#     TokenRequest API (`kubectl create token`).
#   * The client authenticates by putting that token in the HTTP header:
#         Authorization: Bearer <token>
#   * The cluster (not you) owns the signing key, so tokens can expire and
#     be scoped to an audience.
#
# Run against ANY cluster where you are already an admin (minikube, kind,
# k3s, EKS, GKE, ...). Nothing here needs access to the cluster CA key.

set -euo pipefail

NS="auth-demo"
SA="token-user"

echo "==> [1/4] Create namespace '${NS}' (idempotent)"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/4] Create ServiceAccount '${SA}' in '${NS}'"
kubectl create serviceaccount "${SA}" -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [3/4] Grant RBAC: read-only access to pods in '${NS}'"
kubectl apply -f "$(dirname "$0")/../rbac/token-rbac.yaml"

echo "==> [4/4] Done. The identity now EXISTS and is AUTHORIZED."
echo
echo "Note: In Kubernetes 1.24+, ServiceAccounts do NOT get a long-lived"
echo "      token Secret automatically. We mint a short-lived token on demand"
echo "      in demo.sh using the TokenRequest API. This is the modern, secure"
echo "      default — tokens expire instead of living forever in a Secret."
echo
echo "Next: run ./demo.sh"
