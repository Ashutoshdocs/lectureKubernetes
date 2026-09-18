#!/usr/bin/env bash
#
# setup.sh — Install and configure the Kubernetes Metrics Server.
#
# The HPA cannot read CPU/memory without metrics-server. On local/dev clusters
# (kubeadm, kind, minikube, k3s) metrics-server also needs two extra flags,
# which this script patches in idempotently.
#
set -euo pipefail

METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.8.1}"
NS="kube-system"

echo "==> Installing metrics-server ${METRICS_SERVER_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

echo "==> Ensuring dev-cluster flags are present"
# --kubelet-insecure-tls .............. accept the kubelet's self-signed cert
# --kubelet-preferred-address-types ... reach the node via its InternalIP
current_args="$(kubectl get deployment metrics-server -n "${NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].args}')"

if echo "${current_args}" | grep -q -- '--kubelet-insecure-tls'; then
  echo "    Flags already present — skipping patch."
else
  kubectl patch deployment metrics-server -n "${NS}" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}
  ]'
fi

echo "==> Rolling out metrics-server"
kubectl rollout restart deployment metrics-server -n "${NS}"
kubectl rollout status  deployment metrics-server -n "${NS}" --timeout=120s

echo "==> Waiting for metrics to become available (can take ~30-60s)"
for _ in $(seq 1 24); do
  if kubectl top nodes >/dev/null 2>&1; then
    echo
    echo "Metrics are live:"
    kubectl top nodes
    echo
    echo "Setup complete. Next: ./deploy   (or)   kubectl apply -f deployment.yaml -f service.yaml -f hpa.yaml"
    exit 0
  fi
  sleep 5
done

echo
echo "WARNING: 'kubectl top nodes' is still not returning metrics."
echo "Check the logs and the APIService status:"
echo "  kubectl logs -n ${NS} deployment/metrics-server"
echo "  kubectl get apiservice v1beta1.metrics.k8s.io"
exit 1
