#!/usr/bin/env bash
# Scenario 1 — Terminal shell in a container.
#
# WHAT IT DOES: exec's an interactive shell inside the running victim pod.
# THE SYSCALL:  execve() of /bin/sh with a tty attached.
# THE RULE:     "Terminal shell in container" (default falco_rules.yaml).
# WHY IT MATTERS: an interactive shell in a running prod container is one of
#   the highest-signal indicators of a live intrusion — nobody should be
#   shelling into an immutable workload.
set -euo pipefail

NS=demo-apps
POD=$(kubectl -n "$NS" get pod -l app=victim -o jsonpath='{.items[0].metadata.name}')

echo "[*] Spawning an interactive shell inside $POD ..."
# `-i -t` gives it a tty, which is what the rule keys on.
kubectl -n "$NS" exec -it "$POD" -- /bin/sh -c 'echo "hello from inside the container"; id'

echo "[✓] Done. Look for 'Terminal shell in container' (NOTICE) in the Falco stream."
