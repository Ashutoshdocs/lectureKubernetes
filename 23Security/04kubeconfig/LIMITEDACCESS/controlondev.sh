#!/bin/bash

set -e

echo "================================================"
echo " Kubernetes DEV Namespace Admin User"
echo "================================================"

USERNAME="dev-admin-user"
NAMESPACE="dev"

API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

CA_CERT="/etc/kubernetes/pki/ca.crt"
CA_KEY="/etc/kubernetes/pki/ca.key"

OUTPUT="/home/azure/dev-admin.conf"

echo ""
echo "User        : $USERNAME"
echo "Namespace   : $NAMESPACE"
echo "API Server  : $API_SERVER"
echo ""

if [ ! -f "$CA_CERT" ]; then
    echo "ERROR: CA certificate not found:"
    echo "$CA_CERT"
    exit 1
fi

if [ ! -f "$CA_KEY" ]; then
    echo "ERROR: CA private key not found:"
    echo "$CA_KEY"
    exit 1
fi

echo "[1/7] Checking namespace..."

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: Namespace '$NAMESPACE' does not exist."
    echo "Create it first:"
    echo "kubectl create namespace $NAMESPACE"
    exit 1
fi

echo "[2/7] Creating full-access Role..."

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-admin
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF

echo "[3/7] Creating RoleBinding..."

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-admin-binding
  namespace: ${NAMESPACE}
subjects:
- kind: User
  name: ${USERNAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: dev-admin
  apiGroup: rbac.authorization.k8s.io
EOF

echo "[4/7] Generating client private key..."

openssl genrsa -out /tmp/${USERNAME}.key 2048

echo "[5/7] Creating certificate signing request..."

openssl req \
  -new \
  -key /tmp/${USERNAME}.key \
  -out /tmp/${USERNAME}.csr \
  -subj "/CN=${USERNAME}"

echo "[6/7] Signing client certificate..."

openssl x509 \
  -req \
  -in /tmp/${USERNAME}.csr \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out /tmp/${USERNAME}.crt \
  -days 365

echo "[7/7] Creating restricted kubeconfig..."

kubectl config set-cluster kubernetes \
  --server="$API_SERVER" \
  --certificate-authority="$CA_CERT" \
  --embed-certs=true \
  --kubeconfig="$OUTPUT"

kubectl config set-credentials "$USERNAME" \
  --client-certificate=/tmp/${USERNAME}.crt \
  --client-key=/tmp/${USERNAME}.key \
  --embed-certs=true \
  --kubeconfig="$OUTPUT"

kubectl config set-context "${USERNAME}@kubernetes" \
  --cluster=kubernetes \
  --user="$USERNAME" \
  --namespace="$NAMESPACE" \
  --kubeconfig="$OUTPUT"

kubectl config use-context "${USERNAME}@kubernetes" \
  --kubeconfig="$OUTPUT"

chown azure:azure "$OUTPUT"
chmod 600 "$OUTPUT"

rm -f /tmp/${USERNAME}.key
rm -f /tmp/${USERNAME}.crt
rm -f /tmp/${USERNAME}.csr
rm -f /tmp/${USERNAME}.csr-key.pem
rm -f "${CA_CERT}.srl"

echo ""
echo "================================================"
echo " SUCCESS"
echo "================================================"
echo ""
echo "Kubeconfig:"
echo "$OUTPUT"
echo ""
echo "Download from laptop:"
echo ""
echo "scp azure@<PUBLIC-IP>:$OUTPUT ./dev-admin.conf"
echo ""
echo "Test:"
echo ""
echo "kubectl --kubeconfig=./dev-admin.conf get pods -n dev"
echo "kubectl --kubeconfig=./dev-admin.conf create deployment nginx --image=nginx -n dev"
echo ""
echo "================================================"