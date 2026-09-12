#!/usr/bin/env bash
#
# Demo 1 — TOKEN-BASED AUTHENTICATION (the actual demo)
# -----------------------------------------------------
# Builds a kubeconfig that logs in as the ServiceAccount using ONLY a bearer
# token, then proves the RBAC boundary works (allowed vs denied).

set -euo pipefail

NS="auth-demo"
SA="token-user"
KUBECONFIG_OUT="/tmp/token-user.kubeconfig"
TTL="3600"   # token lifetime in seconds (1 hour)

# ---- Discover the current cluster's API server + CA so we can talk to it ----
CTX="$(kubectl config current-context)"
CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.cluster}")"
APISERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.server}")"
# The cluster CA lets the CLIENT verify the SERVER. (This is TLS server auth —
# NOT client auth. Every kubeconfig needs it regardless of how you log in.)
CA_DATA="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.certificate-authority-data}")"

echo "==> [1/4] Mint a short-lived bearer token for '${SA}' (TTL=${TTL}s)"
TOKEN="$(kubectl create token "${SA}" -n "${NS}" --duration="${TTL}s")"
echo "    Token (first 40 chars): ${TOKEN:0:40}..."
echo "    It's a JWT — decode the middle section to see the claims:"
echo "${TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | sed 's/^/      /' || true
echo

echo "==> [2/4] Build a kubeconfig that authenticates with the TOKEN only"
cat > "${KUBECONFIG_OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: demo-cluster
  cluster:
    server: ${APISERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${SA}
  user:
    token: ${TOKEN}          # <-- THE ONLY CREDENTIAL. No client cert/key.
contexts:
- name: token-ctx
  context:
    cluster: demo-cluster
    user: ${SA}
    namespace: ${NS}
current-context: token-ctx
EOF
echo "    Wrote ${KUBECONFIG_OUT}"
echo "    Notice: user.user has ONLY 'token'. That is the whole identity."
echo

echo "==> [3/4] Who does the cluster think we are?"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl auth whoami || true
echo "    Expect username like: system:serviceaccount:${NS}:${SA}"
echo

echo "==> [4/4] Test the RBAC boundary"
echo "    (a) ALLOWED — list pods in '${NS}':"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl get pods -n "${NS}" || true
echo
echo "    (b) DENIED — list secrets in '${NS}' (not granted):"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl get secrets -n "${NS}" || true
echo
echo "    (c) DENIED — list pods in kube-system (wrong namespace):"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl get pods -n kube-system || true
echo
echo "Done. Authentication = the token. Authorization = RBAC decided the rest."
echo "The token expires in ${TTL}s; after that this kubeconfig stops working."
