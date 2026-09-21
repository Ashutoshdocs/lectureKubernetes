#!/usr/bin/env bash
# Scenario 3 — Write below /etc.
#
# WHAT IT DOES: writes a file into /etc inside the victim pod.
# THE SYSCALL:  openat(O_WRONLY|O_CREAT) under /etc.
# THE RULE:     "Write below etc" (default falco_rules.yaml).
# WHY IT MATTERS: tampering with /etc (cron, passwd, ld.so.preload) is a
#   common persistence / privilege-escalation move. An immutable container
#   should never see writes here at runtime.
set -euo pipefail

NS=demo-apps
POD=$(kubectl -n "$NS" get pod -l app=victim -o jsonpath='{.items[0].metadata.name}')

echo "[*] Writing /etc/falco-demo-marker inside $POD ..."
kubectl -n "$NS" exec "$POD" -- sh -c 'echo pwned > /etc/falco-demo-marker || true'

echo "[✓] Done. Look for 'Write below etc' (ERROR) in the Falco stream."
