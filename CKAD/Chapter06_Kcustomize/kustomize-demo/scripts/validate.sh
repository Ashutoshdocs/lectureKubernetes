#!/usr/bin/env bash
# Renders every kustomization and (optionally) schema-validates the output.
# Good for CI: fails fast if any overlay is broken.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v kustomize >/dev/null; then BUILD="kustomize build"; else BUILD="kubectl kustomize"; fi
[ -f overlays/prod/secrets.env ] || cp overlays/prod/secrets.env.example overlays/prod/secrets.env

status=0
for dir in base overlays/dev overlays/staging overlays/prod; do
  if out=$($BUILD "$dir" 2>&1); then
    count=$(grep -c '^kind:' <<<"$out")
    printf "  OK    %-18s %s objects\n" "$dir" "$count"
    if command -v kubeconform >/dev/null; then
      kubeconform -strict -summary <<<"$out" || status=1
    fi
  else
    printf "  FAIL  %s\n%s\n" "$dir" "$out"; status=1
  fi
done

command -v kubeconform >/dev/null || echo "  (install kubeconform for schema validation)"
exit $status
