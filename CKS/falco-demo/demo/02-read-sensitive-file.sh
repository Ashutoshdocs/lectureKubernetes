#!/usr/bin/env bash
# Scenario 2 — Read a sensitive file.
#
# WHAT IT DOES: cats /etc/shadow inside the victim pod.
# THE SYSCALL:  openat()/read() on /etc/shadow.
# THE RULE:     "Read sensitive file untrusted" (default) AND our custom
#               "Sensitive file read in demo namespace".
# WHY IT MATTERS: reads of credential files are a classic credential-access
#   step (MITRE T1003). Almost no legitimate app reads /etc/shadow at runtime.
set -euo pipefail

NS=demo-apps
POD=$(kubectl -n "$NS" get pod -l app=victim -o jsonpath='{.items[0].metadata.name}')

echo "[*] Reading /etc/shadow inside $POD ..."
kubectl -n "$NS" exec "$POD" -- sh -c 'cat /etc/shadow || true' >/dev/null

echo "[✓] Done. Look for 'sensitive file' alerts (WARNING) in the Falco stream."
