#!/usr/bin/env bash
#
# Demo 2 — CERTIFICATE-BASED AUTHENTICATION (X.509 client certs)
# --------------------------------------------------------------
# What this shows:
#   * YOU generate a private key and a CSR locally.
#   * The cluster CA *signs* your CSR, producing a client certificate.
#   * Identity is baked into the cert itself:
#         Subject CN  ->  Kubernetes username
#         Subject O   ->  Kubernetes group(s)
#   * The client authenticates by presenting the cert during the TLS
#     handshake (mutual TLS). No bearer token, no header.
#
# We use the CertificateSigningRequest (CSR) API so this works on any cluster
# without needing direct filesystem access to the CA private key.
#
# IMPORTANT: There is NO User object in Kubernetes. Signing a cert with a CN is
# literally how you "create" a human/external user. The cluster trusts anything
# its CA signed.

set -euo pipefail

NS="auth-demo"
USERNAME="cert-user"          # becomes the CN  -> k8s username
GROUP="demo-readers"          # becomes the O   -> k8s group
WORKDIR="$(cd "$(dirname "$0")" && pwd)/pki"
CSR_NAME="${USERNAME}-csr"

mkdir -p "${WORKDIR}"

echo "==> [1/6] Ensure namespace '${NS}' exists"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/6] Generate a private key (stays on the client, never sent anywhere)"
openssl genrsa -out "${WORKDIR}/${USERNAME}.key" 2048 2>/dev/null
echo "    -> ${WORKDIR}/${USERNAME}.key"

echo "==> [3/6] Create a CSR with Subject CN=${USERNAME}, O=${GROUP}"
openssl req -new \
  -key "${WORKDIR}/${USERNAME}.key" \
  -out "${WORKDIR}/${USERNAME}.csr" \
  -subj "/CN=${USERNAME}/O=${GROUP}"
echo "    -> ${WORKDIR}/${USERNAME}.csr"
echo "    (CN and O are the entire identity — the cluster reads them from the cert)"

echo "==> [4/6] Submit the CSR to the cluster's CertificateSigningRequest API"
REQUEST_B64="$(base64 -w0 < "${WORKDIR}/${USERNAME}.csr" 2>/dev/null || base64 < "${WORKDIR}/${USERNAME}.csr" | tr -d '\n')"
kubectl delete csr "${CSR_NAME}" --ignore-not-found >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: ${REQUEST_B64}
  signerName: kubernetes.io/kube-apiserver-client   # signer for CLIENT auth certs
  expirationSeconds: 86400                            # 1 day
  usages:
  - client auth
EOF

echo "==> [5/6] Approve the CSR (an admin action — this is your 'access review')"
kubectl certificate approve "${CSR_NAME}"

echo "==> [5b] Wait for the signed certificate to appear..."
for i in $(seq 1 10); do
  CERT="$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)"
  [ -n "${CERT}" ] && break
  sleep 1
done
if [ -z "${CERT:-}" ]; then
  echo "ERROR: certificate was not issued. Check that a signer is running"
  echo "       (some managed clusters, e.g. certain EKS/GKE setups, do not run"
  echo "       the kube-controller-manager signer for this signerName). See the"
  echo "       README section 'Direct CA signing' for the fallback method."
  exit 1
fi
echo "${CERT}" | base64 -d > "${WORKDIR}/${USERNAME}.crt"
echo "    -> ${WORKDIR}/${USERNAME}.crt (signed by the cluster CA)"

echo "==> [6/6] Grant RBAC to the GROUP '${GROUP}' (read-only pods in '${NS}')"
kubectl apply -f "$(dirname "$0")/../rbac/cert-rbac.yaml"

echo
echo "Done. Inspect the identity that got signed into the cert:"
openssl x509 -in "${WORKDIR}/${USERNAME}.crt" -noout -subject -issuer -dates | sed 's/^/    /'
echo
echo "Next: run ./demo.sh"
