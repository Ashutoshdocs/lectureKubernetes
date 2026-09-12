#!/usr/bin/env bash
#
# Demo 2 — CERTIFICATE-BASED AUTHENTICATION (the actual demo)
# -----------------------------------------------------------
# Builds a kubeconfig that logs in with a client cert + key (mutual TLS),
# then proves the RBAC boundary works.

set -euo pipefail

NS="auth-demo"
USERNAME="cert-user"
WORKDIR="$(cd "$(dirname "$0")" && pwd)/pki"
KUBECONFIG_OUT="/tmp/cert-user.kubeconfig"

CRT="${WORKDIR}/${USERNAME}.crt"
KEY="${WORKDIR}/${USERNAME}.key"

if [ ! -f "${CRT}" ] || [ ! -f "${KEY}" ]; then
  echo "ERROR: cert/key not found. Run ./setup.sh first."
  exit 1
fi

# ---- Discover the current cluster's API server + CA ----
CTX="$(kubectl config current-context)"
CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.cluster}")"
APISERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.server}")"
CA_DATA="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.certificate-authority-data}")"

CRT_B64="$(base64 -w0 < "${CRT}" 2>/dev/null || base64 < "${CRT}" | tr -d '\n')"
KEY_B64="$(base64 -w0 < "${KEY}" 2>/dev/null || base64 < "${KEY}" | tr -d '\n')"

echo "==> [1/3] Build a kubeconfig that authenticates with a CLIENT CERT"
cat > "${KUBECONFIG_OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: demo-cluster
  cluster:
    server: ${APISERVER}
    certificate-authority-data: ${CA_DATA}     # verifies the SERVER (TLS server auth)
users:
- name: ${USERNAME}
  user:
    client-certificate-data: ${CRT_B64}        # proves the CLIENT (TLS client auth)
    client-key-data: ${KEY_B64}                # the private key never leaves you
contexts:
- name: cert-ctx
  context:
    cluster: demo-cluster
    user: ${USERNAME}
    namespace: ${NS}
current-context: cert-ctx
EOF
echo "    Wrote ${KUBECONFIG_OUT}"
echo "    Notice: user.user has client-certificate-data + client-key-data,"
echo "    and NO token. Identity comes from the cert's CN/O during the TLS handshake."
echo

echo "==> [2/3] Who does the cluster think we are?"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl auth whoami || true
echo "    Expect Username: ${USERNAME}   Groups: [demo-readers ...]"
echo

echo "==> [3/3] Test the RBAC boundary"
echo "    (a) ALLOWED — list pods in '${NS}':"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl get pods -n "${NS}" || true
echo
echo "    (b) DENIED — list secrets in '${NS}' (not granted):"
KUBECONFIG="${KUBECONFIG_OUT}" kubectl get secrets -n "${NS}" || true
echo
echo "Done. Authentication = the signed cert. Authorization = RBAC via the group."
echo
echo "GOTCHA: kube-apiserver does NOT check a CRL. You canNOT revoke this cert"
echo "before it expires. To 'revoke', delete the RBAC binding or rotate the CA."
