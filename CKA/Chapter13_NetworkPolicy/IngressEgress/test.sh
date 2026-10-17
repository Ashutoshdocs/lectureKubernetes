#!/usr/bin/env bash
# NetworkPolicy demo - connectivity test matrix.
#
#   ./test.sh        -> just show what is ALLOWED / BLOCKED right now
#   ./test.sh 3      -> also compare every result with what stage 3 should give
#
set -u

STAGE="${1:-}"
TIMEOUT=6   # seconds per check (run inside the pod, so no host `timeout` needed)

# Expected result for each check, in order (Y = allowed, N = blocked).
# Check numbers:     1 2 3 4 5 6 7 8 9 10 11
declare -A EXPECTED=(
  [0]="YYYYYYYYYYY"   # no policies
  [1]="NNNNNNNNYYY"   # + default-deny ingress
  [2]="YNNYNYNNYYY"   # + allow ingress
  [3]="YNNNNNNNNNN"   # + default-deny egress
  [4]="YNNNNNNNYNN"   # + allow DNS egress
  [5]="YNNYNYNNYNY"   # + allow egress
)

if [[ -n "$STAGE" && -z "${EXPECTED[$STAGE]:-}" ]]; then
  echo "Unknown stage '$STAGE' - use 0, 1, 2, 3, 4 or 5"; exit 1
fi

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_BAD=""; C_B=""; C_0=""
fi

FE=http://frontend.shop.svc.cluster.local
BE=http://backend.shop.svc.cluster.local
DB=http://db.shop.svc.cluster.local
NET=http://example.com

echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pod --all -n shop --timeout=120s >/dev/null || exit 1
kubectl wait --for=condition=Ready pod/client -n outsider --timeout=120s >/dev/null || exit 1

echo
if [[ -n "$STAGE" ]]; then
  echo "${C_B}Connectivity matrix (checking against stage $STAGE)${C_0}"
else
  echo "${C_B}Connectivity matrix${C_0}"
fi
echo "-------------------------------------------------------------"

idx=0
mismatches=0

# check <description> <namespace> <exec target> <command...>
check() {
  local desc="$1" ns="$2" target="$3"; shift 3
  local got shown want verdict
  if kubectl exec -n "$ns" "$target" -- timeout "$TIMEOUT" "$@" >/dev/null 2>&1; then
    got=Y; shown="${C_OK}ALLOWED${C_0}"
  else
    got=N; shown="${C_BAD}BLOCKED${C_0}"
  fi

  if [[ -n "$STAGE" ]]; then
    want="${EXPECTED[$STAGE]:$idx:1}"
    if [[ "$got" == "$want" ]]; then
      verdict="${C_OK}✔ as expected${C_0}"
    else
      [[ "$want" == Y ]] && verdict="${C_BAD}✘ expected ALLOWED${C_0}" || verdict="${C_BAD}✘ expected BLOCKED${C_0}"
      mismatches=$((mismatches + 1))
    fi
    printf " %2d. %-34s %s   %s\n" $((idx + 1)) "$desc" "$shown" "$verdict"
  else
    printf " %2d. %-34s %s\n" $((idx + 1)) "$desc" "$shown"
  fi
  idx=$((idx + 1))
}

WGET=(wget -q -O /dev/null -T 3)

check "outsider -> frontend"            outsider client         "${WGET[@]}" "$FE"
check "outsider -> backend"             outsider client         "${WGET[@]}" "$BE"
check "outsider -> db"                  outsider client         "${WGET[@]}" "$DB"
check "frontend -> backend"             shop     deploy/frontend "${WGET[@]}" "$BE"
check "frontend -> db"                  shop     deploy/frontend "${WGET[@]}" "$DB"
check "backend  -> db"                  shop     deploy/backend  "${WGET[@]}" "$DB"
check "backend  -> frontend"            shop     deploy/backend  "${WGET[@]}" "$FE"
check "db       -> backend"             shop     deploy/db       "${WGET[@]}" "$BE"
check "frontend DNS lookup (kube-dns)"  shop     deploy/frontend nslookup backend.shop.svc.cluster.local
check "frontend -> internet"            shop     deploy/frontend "${WGET[@]}" "$NET"
check "backend  -> internet"            shop     deploy/backend  "${WGET[@]}" "$NET"

echo "-------------------------------------------------------------"

# Show the actual message when the front door is open.
sample=$(kubectl exec -n outsider client -- timeout "$TIMEOUT" wget -q -O - -T 3 "$FE" 2>/dev/null)
[[ -n "$sample" ]] && echo "Sample reply from frontend: $sample"

if [[ -n "$STAGE" ]]; then
  if (( mismatches == 0 )); then
    echo "${C_OK}All $idx checks match stage $STAGE.${C_0}"
  else
    echo "${C_BAD}$mismatches of $idx checks differ from stage $STAGE.${C_0}"
    if [[ "$STAGE" != 0 ]] && [[ "$(kubectl get networkpolicy -n shop -o name | wc -l)" -gt 0 ]]; then
      echo "Hint: if everything shows ALLOWED, your CNI is not enforcing NetworkPolicy (see README > Troubleshooting)."
    fi
    exit 1
  fi
fi
