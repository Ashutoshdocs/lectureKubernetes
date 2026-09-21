#!/usr/bin/env bash
# =============================================================================
# seed-and-verify.sh - the kubectl-side (controlplane) half of the demo.
# The crictl steps must run ON THE NODE (see README); this script does
# everything you can do from the control plane and prints the node commands.
#
#   ./seed-and-verify.sh seed     # write data to hostPath + to the rootfs
#   ./seed-and-verify.sh before   # snapshot state before crictl stop
#   ./seed-and-verify.sh after    # verify state after the container restart
# =============================================================================
set -euo pipefail
POD=nginx-sidecar
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

seed(){
  say "SEED 1: write to the hostPath VOLUME (/shared) from INSIDE the pod"
  kubectl exec "$POD" -c sidecar -- sh -c 'echo "persist-me written INSIDE pod at $(date -u)" > /shared/persist.txt'
  kubectl exec "$POD" -c sidecar -- cat /shared/persist.txt

  say "SEED 2: write to the CONTAINER ROOTFS (ephemeral writable layer)"
  # /tmp is part of the container's own writable layer, NOT the volume.
  kubectl exec "$POD" -c nginx   -- sh -c 'echo "ephemeral nginx"   > /tmp/ephemeral.txt; ls -l /tmp/ephemeral.txt'
  kubectl exec "$POD" -c sidecar -- sh -c 'echo "ephemeral sidecar" > /tmp/ephemeral.txt; ls -l /tmp/ephemeral.txt'

  say "Node command to also seed the volume FROM OUTSIDE (run on the node):"
  echo "  ssh <node> 'echo \"from-node \$(date -u)\" >> /data/shared/from-node.txt'"
}

before(){
  say "BEFORE crictl stop - pod restart counters (expect RESTARTS 0)"
  kubectl get pod "$POD" -o wide
  say "BEFORE - volume contents (/shared) and sidecar.log length"
  kubectl exec "$POD" -c sidecar -- sh -c 'ls -l /shared; echo "sidecar.log lines:"; wc -l < /shared/sidecar.log'
  say "BEFORE - ephemeral rootfs file exists"
  kubectl exec "$POD" -c sidecar -- sh -c 'cat /tmp/ephemeral.txt'
  cat <<'EOF'

NOW RUN ON THE NODE (see README step 4):
  ssh <node>
  crictl ps | grep nginx-sidecar          # note the two CONTAINER IDs + ATTEMPT 0
  crictl stop <sidecar-id> <nginx-id>     # kubelet will restart them
  crictl ps | grep nginx-sidecar          # new IDs, ATTEMPT 1
  exit
EOF
}

after(){
  say "AFTER restart - RESTARTS should have incremented, still 2/2 Running"
  kubectl get pod "$POD" -o wide
  say "PROOF A: hostPath VOLUME data SURVIVED (/shared/persist.txt still there)"
  kubectl exec "$POD" -c sidecar -- cat /shared/persist.txt || echo "MISSING (unexpected!)"
  kubectl exec "$POD" -c sidecar -- cat /shared/from-node.txt 2>/dev/null || echo "(from-node.txt: seed it on the node if you want this line)"
  say "PROOF B: ephemeral ROOTFS data is GONE (/tmp/ephemeral.txt wiped)"
  kubectl exec "$POD" -c sidecar -- sh -c 'cat /tmp/ephemeral.txt 2>&1 || echo "GONE (expected) - fresh writable layer"'
  say "PROOF C: sidecar.log persisted AND grew (see the new STARTED marker)"
  kubectl exec "$POD" -c sidecar -- sh -c 'grep "STARTED" /shared/sidecar.log; echo "total lines now:"; wc -l < /shared/sidecar.log'
}

case "${1:-}" in
  seed) seed ;;
  before) before ;;
  after) after ;;
  *) grep -E '^#   \./seed' "$0" | sed 's/^# //'; exit 1 ;;
esac
