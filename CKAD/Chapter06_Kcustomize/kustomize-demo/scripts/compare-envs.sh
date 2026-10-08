#!/usr/bin/env bash
# Side-by-side diff of two rendered environments — great for showing students
# exactly what an overlay changes.   Usage: ./scripts/compare-envs.sh dev prod
set -euo pipefail
cd "$(dirname "$0")/.."
A=${1:-dev}; B=${2:-prod}
if command -v kustomize >/dev/null; then BUILD="kustomize build"; else BUILD="kubectl kustomize"; fi
[ -f overlays/prod/secrets.env ] || cp overlays/prod/secrets.env.example overlays/prod/secrets.env

path() { [ "$1" = base ] && echo base || echo "overlays/$1"; }
diff -u --label "$A" --label "$B" <($BUILD "$(path "$A")") <($BUILD "$(path "$B")") || true
