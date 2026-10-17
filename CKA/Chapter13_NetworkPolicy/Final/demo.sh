#!/usr/bin/env bash
# Guided NetworkPolicy demo: ingress vs egress.
# Usage:  ./demo.sh          (pauses between steps)
#         AUTO=1 ./demo.sh   (no pauses)
set -uo pipefail
cd "$(dirname "$0")"

B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'

pause()  { [[ "${AUTO:-0}" == "1" ]] && return; echo; read -rp "${Y}▶ Press Enter to continue...${N}" _; }
header() { echo; echo "${B}${C}══════════════════════════════════════════════════════════════${N}"; echo "${B}${C}  $1${N}"; echo "${B}${C}══════════════════════════════════════════════════════════════${N}"; }
run()    { echo "${B}\$ $*${N}"; "$@"; }

# probe <from-ns> <from-pod> <label> <url>
probe() {
  local ns=$1 pod=$2 label=$3 url=$4 out rc
  out=$(kubectl exec -n "$ns" "$pod" -- curl -s --max-time 3 "$url" 2>/dev/null); rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "  %-34s ${G}✔ ALLOWED${N}  → %s\n" "$label" "$out"
  else
    local why="exit $rc"
    [[ $rc -eq 6  ]] && why="DNS lookup failed"
    [[ $rc -eq 28 ]] && why="timed out (dropped)"
    [[ $rc -eq 7  ]] && why="connection refused"
    printf "  %-34s ${R}✘ BLOCKED${N}  (%s)\n" "$label" "$why"
  fi
}

test_all() {
  echo
  echo "${B}  Traffic tests:${N}"
  probe team-a pod-a "pod-a → pod-b  (service DNS)" "http://web.team-b.svc.cluster.local"
  probe team-a pod-a "pod-a → pod-b  (pod IP $IP_B)" "http://$IP_B"
  probe team-b pod-b "pod-b → pod-a  (service DNS)" "http://web.team-a.svc.cluster.local"
  probe team-b pod-b "pod-b → pod-a  (pod IP $IP_A)" "http://$IP_A"
}

reset_policies() {
  kubectl delete networkpolicy --all -n team-a --ignore-not-found >/dev/null
  kubectl delete networkpolicy --all -n team-b --ignore-not-found >/dev/null
}

# ─────────────────────────────────────────────────────────────
header "STEP 0 — Setup: 2 namespaces, 2 nginx pods"
run kubectl apply -f 00-setup.yaml
kubectl wait --for=condition=Ready pod/pod-a -n team-a --timeout=120s >/dev/null
kubectl wait --for=condition=Ready pod/pod-b -n team-b --timeout=120s >/dev/null
reset_policies
IP_A=$(kubectl get pod pod-a -n team-a -o jsonpath='{.status.podIP}')
IP_B=$(kubectl get pod pod-b -n team-b -o jsonpath='{.status.podIP}')
echo
run kubectl get pods -n team-a -o wide
run kubectl get pods -n team-b -o wide

# ─────────────────────────────────────────────────────────────
header "STEP 1 — Baseline: no policies → everything is allowed"
cat <<EOF
  Kubernetes is ${B}default-allow${N}. Until a NetworkPolicy selects a pod,
  that pod can send to and receive from anything.
EOF
test_all
pause

# ─────────────────────────────────────────────────────────────
header "STEP 2 — DENY ALL INGRESS in team-b"
cat <<EOF
  ${B}Ingress${N} = traffic coming ${B}INTO${N} the selected pod.
  We isolate every pod in team-b for incoming traffic and allow nothing.
EOF
echo; cat 01-deny-all-ingress-team-b.yaml | sed 's/^/    /'
echo; run kubectl apply -f 01-deny-all-ingress-team-b.yaml
sleep 2
test_all
cat <<EOF

  ${B}Why?${N}
   • pod-a → pod-b is blocked: pod-b now refuses all incoming connections.
     (DNS still worked — pod-a's egress is untouched — but the TCP connect times out.)
   • pod-b → pod-a still works: the policy only covers INGRESS to team-b.
     pod-b's outgoing request is fine, and the ${B}reply${N} from pod-a comes back
     because NetworkPolicy is ${B}stateful${N} — replies to allowed connections are allowed.
EOF
pause

# ─────────────────────────────────────────────────────────────
header "STEP 3 — DENY ALL EGRESS in team-a (scenario 2 removed first)"
reset_policies
cat <<EOF
  ${B}Egress${N} = traffic going ${B}OUT OF${N} the selected pod.
  We isolate every pod in team-a for outgoing traffic and allow nothing.
EOF
echo; cat 02-deny-all-egress-team-a.yaml | sed 's/^/    /'
echo; run kubectl apply -f 02-deny-all-egress-team-a.yaml
sleep 2
test_all
cat <<EOF

  ${B}Why?${N}
   • pod-a → pod-b by name fails at ${B}DNS${N}: the lookup to CoreDNS (UDP/TCP 53)
     is itself egress — and egress is denied. By IP it times out instead.
     ${Y}Real-world lesson: a deny-egress policy almost always needs a DNS allow rule.${N}
   • pod-b → pod-a still works: ingress to pod-a was never restricted, and
     pod-a's ${B}reply${N} is not "new egress" — stateful tracking lets it out.
EOF
pause

# ─────────────────────────────────────────────────────────────
header "STEP 4 — pod-b: INGRESS allowed + EGRESS denied (same pod)"
reset_policies
echo; cat 03-pod-b-allow-ingress-deny-egress.yaml | sed 's/^/    /'
echo; run kubectl apply -f 03-pod-b-allow-ingress-deny-egress.yaml
sleep 2
test_all
echo
echo "${B}  Extra check — loopback inside pod-b (never filtered):${N}"
probe team-b pod-b "pod-b → localhost" "http://localhost"
cat <<EOF

  ${B}Why?${N}
   • pod-a → pod-b works: ingress from team-a on port 80 is explicitly allowed,
     and pod-b's response leaves even though egress is denied (stateful reply).
   • pod-b → pod-a fails: pod-b may not ${B}start${N} any outgoing connection —
     not even the DNS lookup.
   • localhost always works: NetworkPolicy only filters traffic on the pod's network interface.
EOF
pause

# ─────────────────────────────────────────────────────────────
header "STEP 5 — Policies currently in place"
run kubectl get networkpolicy -A
run kubectl describe networkpolicy pod-b-ingress-allow-egress-deny -n team-b

echo
echo "${B}Done.${N} Clean up with:  ${B}kubectl delete ns team-a team-b${N}"
