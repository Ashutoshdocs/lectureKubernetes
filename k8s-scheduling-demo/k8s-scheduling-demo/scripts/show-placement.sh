#!/usr/bin/env bash
# Shows which node + zone every demo pod runs on, and a per-node/per-zone count.
# Usage: ./show-placement.sh            (all demo pods)
#        ./show-placement.sh web        (only pods with label app=web)
set -uo pipefail
NS=scheduling-demo
SEL=${1:+-l app=$1}

declare -A ZONE
while read -r node zone; do ZONE[$node]=${zone:-none}; done < <(
  kubectl get nodes -o custom-columns='N:.metadata.name,Z:.metadata.labels.topology\.kubernetes\.io/zone' --no-headers)

printf "%-34s %-10s %-12s %-8s\n" POD STATUS NODE ZONE
printf "%-34s %-10s %-12s %-8s\n" --- ------ ---- ----
# shellcheck disable=SC2086
kubectl get pods -n "$NS" $SEL --no-headers \
  -o custom-columns='P:.metadata.name,S:.status.phase,N:.spec.nodeName' | sort -k3 |
while read -r pod status node; do
  [[ "$node" == "<none>" ]] && node="-"
  printf "%-34s %-10s %-12s %-8s\n" "$pod" "$status" "$node" "${ZONE[$node]:--}"
done

echo
echo "Pods per node:"
# shellcheck disable=SC2086
kubectl get pods -n "$NS" $SEL --no-headers -o custom-columns='N:.spec.nodeName' | sort | uniq -c
echo "Pods per zone:"
# shellcheck disable=SC2086
kubectl get pods -n "$NS" $SEL --no-headers -o custom-columns='N:.spec.nodeName' |
  while read -r n; do echo "${ZONE[$n]:-pending}"; done | sort | uniq -c
