#!/usr/bin/env bash
# Regenerate the ConfigMap manifests from the source HTML in games/.
# Run this after editing games/tictactoe.html or games/rps.html.
#
# Usage:  ./scripts/build-configmaps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

gen() {
  local cm_name="$1" src="$2" out="$3"
  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: ${cm_name}"
    echo "  namespace: games"
    echo "data:"
    echo "  index.html: |"
    # indent every line of the HTML by 4 spaces
    sed 's/^/    /' "$src"
  } > "$out"
  echo "generated $out from $src"
}

gen "tictactoe-html" "games/tictactoe.html" "manifests/20-tictactoe-configmap.yaml"
gen "rps-html"       "games/rps.html"       "manifests/21-rps-configmap.yaml"

echo "Done. Apply with: kubectl apply -f manifests/"
