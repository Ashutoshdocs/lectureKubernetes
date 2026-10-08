#!/usr/bin/env bash
# Regenerate the ConfigMap manifests from the source files.
# Run this after editing anything in apps/ or nginx/.
#
# Usage:  ./scripts/build-configmaps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# gen <configmap-name> <key> <source-file> <output-manifest> <description>
gen() {
  local cm_name="$1" key="$2" src="$3" out="$4" desc="$5"
  {
    echo "# ---------------------------------------------------------------------------"
    echo "# ${desc}"
    echo "# Generated from ${src} by scripts/build-configmaps.sh."
    echo "# Edit the source file and re-run the script; don't edit this block by hand."
    echo "# ---------------------------------------------------------------------------"
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: ${cm_name}"
    echo "  namespace: webapps"
    echo "data:"
    echo "  ${key}: |"
    # indent every line by 4 spaces (blank lines stay blank)
    sed 's/^\(.\)/    \1/' "$src"
  } > "$out"
  echo "generated $out from $src"
}

gen "nginx-conf" "default.conf" "nginx/default.conf"  "manifests/20-nginx-conf-configmap.yaml" "Shared nginx server config (port 8080, /whoami, /healthz) for all web Pods."
gen "home-html"  "index.html"   "apps/home.html"      "manifests/21-home-configmap.yaml"       "Landing page served at akblazeacademy.net/"
gen "app1-html"  "index.html"   "apps/app1.html"      "manifests/22-app1-configmap.yaml"       "App 1 (TaskFlow to-do manager) served at akblazeacademy.net/app1"
gen "app2-html"  "index.html"   "apps/app2.html"      "manifests/23-app2-configmap.yaml"       "App 2 (Spendly expense tracker) served at akblazeacademy.net/app2"

echo "Done. Apply with: kubectl apply -k manifests/"
