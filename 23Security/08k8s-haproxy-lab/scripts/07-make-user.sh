#!/usr/bin/env bash
###############################################################################
# 07-make-user.sh   -- run ON the control-plane node of the cluster you want
#                       to grant the user access to.
#
# Creates a Kubernetes user the proper way: an x509 client certificate signed
# by THAT cluster's CA. Then it:
#   - grants the user full permissions on THIS cluster (cluster-admin binding)
#   - builds a kubeconfig whose server = HAProxy (NOT the API server directly)
#   - prints/writes the kubeconfig so you can copy it to the clusterwork box.
#
# Because each user's cert is signed by only ONE cluster's CA, that user
# CANNOT authenticate to the other cluster. That is the isolation.
#
# Run on cluster1-cp:
#   sudo USER_NAME=manohar  CLUSTER_NAME=cluster1 HAPROXY_IP=10.0.1.4 PORT=7001 bash 07-make-user.sh
# Run on cluster2-cp:
#   sudo USER_NAME=ashutosh CLUSTER_NAME=cluster2 HAPROXY_IP=10.0.1.4 PORT=7002 bash 07-make-user.sh
###############################################################################
set -euo pipefail

: "${USER_NAME:?set USER_NAME (e.g. manohar)}"
: "${CLUSTER_NAME:?set CLUSTER_NAME (e.g. cluster1)}"
: "${HAPROXY_IP:?set HAPROXY_IP (haproxy private IP)}"
: "${PORT:?set PORT (7001 for cluster1, 7002 for cluster2)}"

PKI=/etc/kubernetes/pki
WORK="/tmp/${USER_NAME}-kube"
OUT="${WORK}/${USER_NAME}.kubeconfig"
mkdir -p "$WORK"; cd "$WORK"

echo ">> [1/4] Generate key + CSR for $USER_NAME"
openssl genrsa -out "${USER_NAME}.key" 2048
# CN = username (RBAC subject). O = a group, handy for group-based rules.
openssl req -new -key "${USER_NAME}.key" \
  -out "${USER_NAME}.csr" \
  -subj "/CN=${USER_NAME}/O=${CLUSTER_NAME}-admins"

echo ">> [2/4] Sign CSR with ${CLUSTER_NAME}'s CA (valid 365 days)"
openssl x509 -req -in "${USER_NAME}.csr" \
  -CA "${PKI}/ca.crt" -CAkey "${PKI}/ca.key" -CAcreateserial \
  -out "${USER_NAME}.crt" -days 365

echo ">> [3/4] Grant FULL permissions on this cluster (cluster-admin)"
KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl create clusterrolebinding "${USER_NAME}-admin" \
  --clusterrole=cluster-admin --user="${USER_NAME}" \
  --dry-run=client -o yaml | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -

echo ">> [4/4] Build kubeconfig pointing at HAProxy (${HAPROXY_IP}:${PORT})"
kubectl config set-cluster "${CLUSTER_NAME}" \
  --server="https://${HAPROXY_IP}:${PORT}" \
  --certificate-authority="${PKI}/ca.crt" --embed-certs=true \
  --kubeconfig="$OUT"
kubectl config set-credentials "${USER_NAME}" \
  --client-certificate="${USER_NAME}.crt" \
  --client-key="${USER_NAME}.key" --embed-certs=true \
  --kubeconfig="$OUT"
kubectl config set-context "${USER_NAME}@${CLUSTER_NAME}" \
  --cluster="${CLUSTER_NAME}" --user="${USER_NAME}" \
  --kubeconfig="$OUT"
kubectl config use-context "${USER_NAME}@${CLUSTER_NAME}" --kubeconfig="$OUT"

echo
echo "======================================================================"
echo " kubeconfig written to: $OUT"
echo
echo " Copy it to the clusterwork box into the user's home, e.g.:"
echo "   scp $OUT azureuser@<clusterwork-pub>:/tmp/"
echo "   ssh azureuser@<clusterwork-pub> \\"
echo "     'sudo install -o ${USER_NAME} -g ${USER_NAME} -m 600 \\"
echo "        /tmp/${USER_NAME}.kubeconfig /home/${USER_NAME}/.kube/config'"
echo "======================================================================"
