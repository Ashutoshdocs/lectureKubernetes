#!/usr/bin/env bash
#
# Negative checks: prove the reporter is DENIED everything outside its Role.
# Each of these SHOULD fail with "Forbidden" -- that's a PASS for the demo.
set -uo pipefail

NS="acme-prod"

step()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
green() { printf '\033[0;32mPASS: %s\033[0m\n' "$*"; }
red()   { printf '\033[0;31mFAIL: %s\033[0m\n' "$*"; }

expect_forbidden() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    red "$desc was ALLOWED (should have been denied)"
  else
    green "$desc was correctly denied"
  fi
}

step "1) reporter reads a Secret -> expect Forbidden (no secrets permission)"
expect_forbidden "reading app-secret" \
  kubectl -n "$NS" exec deploy/reporter -- kubectl get secret app-secret

step "2) reporter reads a different ConfigMap -> expect Forbidden (resourceNames)"
expect_forbidden "reading other-config" \
  kubectl -n "$NS" exec deploy/reporter -- kubectl get configmap other-config

step "3) reporter lists ConfigMaps -> expect Forbidden (only 'get by name' granted)"
expect_forbidden "listing configmaps" \
  kubectl -n "$NS" exec deploy/reporter -- kubectl get configmaps

step "4) reporter deletes a pod -> expect Forbidden (read-only role)"
expect_forbidden "deleting a pod" \
  kubectl -n "$NS" exec deploy/reporter -- kubectl delete pod -l app.kubernetes.io/name=web-app

step "5) reporter reads pods in another namespace -> expect Forbidden (Role is namespaced)"
expect_forbidden "listing pods in kube-system" \
  kubectl -n "$NS" exec deploy/reporter -- kubectl get pods -n kube-system

echo
echo "All five denials above should read PASS."
