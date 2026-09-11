#!/usr/bin/env bash
#
# Positive checks: prove each identity has exactly the access it should.
set -uo pipefail

NS="acme-prod"
APP_SA="system:serviceaccount:${NS}:web-app"
REP_SA="system:serviceaccount:${NS}:reporter"

step()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

step "auth can-i matrix (asking the API server directly, no pods involved)"
printf 'reporter can list pods        : '; kubectl auth can-i list pods                     --as="$REP_SA" -n "$NS"
printf 'reporter can get app-config   : '; kubectl auth can-i get  configmaps/app-config    --as="$REP_SA" -n "$NS"
printf 'reporter can get other-config : '; kubectl auth can-i get  configmaps/other-config  --as="$REP_SA" -n "$NS"
printf 'reporter can get secrets      : '; kubectl auth can-i get  secrets                  --as="$REP_SA" -n "$NS"
printf 'reporter can delete pods      : '; kubectl auth can-i delete pods                    --as="$REP_SA" -n "$NS"
printf 'web-app  can list pods        : '; kubectl auth can-i list pods                     --as="$APP_SA" -n "$NS"

step "The app pod has NO token mounted (automount disabled)"
if kubectl -n "$NS" exec deploy/web-app -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null; then
  echo "unexpected: token dir exists"
else
  green "confirmed: no serviceaccount token directory inside the app pod"
fi

step "The reporter pod CAN read its allowed data from inside the pod"
echo "- pods:"
kubectl -n "$NS" exec deploy/reporter -- kubectl get pods -o name
echo "- app-config:"
kubectl -n "$NS" exec deploy/reporter -- kubectl get configmap app-config -o jsonpath='{.data}'; echo

step "Inspect the reporter's projected token (note the short expiry)"
kubectl -n "$NS" get pod -l app.kubernetes.io/name=reporter \
  -o jsonpath='{.items[0].spec.volumes[?(@.name=="kube-api-access")].projected.sources[0].serviceAccountToken}'; echo
