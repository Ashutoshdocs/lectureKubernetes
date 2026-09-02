#!/usr/bin/env bash
# =============================================================================
# NetworkPolicy Demo — Connectivity Tester
# Runs every pod-to-pod curl and compares the result to what the policies
# should produce. A "BLOCKED" result shows up as a timeout (packets are
# silently dropped), NOT as "connection refused".
#
# Usage:  ./test-connectivity.sh
# =============================================================================
set -u
NS=netpol-demo

echo "Fetching pod IPs..."
IP_A=$(kubectl get pod pod-a -n "$NS" -o jsonpath='{.status.podIP}')
IP_B=$(kubectl get pod pod-b -n "$NS" -o jsonpath='{.status.podIP}')
IP_C=$(kubectl get pod pod-c -n "$NS" -o jsonpath='{.status.podIP}')

if [ -z "$IP_A" ] || [ -z "$IP_B" ] || [ -z "$IP_C" ]; then
  echo "Could not read all pod IPs. Are the pods Running? (kubectl get pods -n $NS -o wide)"
  exit 1
fi
echo "  pod-a = $IP_A"
echo "  pod-b = $IP_B"
echo "  pod-c = $IP_C"
echo

pass=0; fail=0

run() {
  local from="$1" to_name="$2" to_ip="$3" expect="$4"
  local code
  code=$(kubectl exec -n "$NS" "$from" -- \
           curl -s -o /dev/null -w '%{http_code}' \
           --connect-timeout 4 --max-time 6 "http://$to_ip" 2>/dev/null)
  local got
  if [ "$code" = "200" ]; then got="ALLOWED"; else got="BLOCKED"; fi

  local mark
  if [ "$got" = "$expect" ]; then mark="OK  "; pass=$((pass+1)); else mark="FAIL"; fail=$((fail+1)); fi

  printf "[%s] %-6s -> %-6s | expected %-8s | got %-8s\n" \
         "$mark" "$from" "$to_name" "$expect" "$got"
}

echo "Running connectivity matrix..."
echo "-----------------------------------------------------------------"
run pod-a pod-b "$IP_B" BLOCKED
run pod-a pod-c "$IP_C" ALLOWED
run pod-b pod-a "$IP_A" BLOCKED
run pod-b pod-c "$IP_C" ALLOWED
run pod-c pod-a "$IP_A" BLOCKED
run pod-c pod-b "$IP_B" BLOCKED
echo "-----------------------------------------------------------------"
echo "Passed: $pass   Failed: $fail"
echo
if [ "$fail" -ne 0 ]; then
  echo "If everything shows ALLOWED, your CNI probably does NOT enforce"
  echo "NetworkPolicy (e.g. plain flannel). Use Calico / Cilium / Weave / Antrea."
fi
