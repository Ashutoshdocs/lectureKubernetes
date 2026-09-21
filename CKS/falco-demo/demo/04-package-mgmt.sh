#!/usr/bin/env bash
# Scenario 4 — Package manager launched in a running container.
#
# WHAT IT DOES: runs `apk add` inside the victim pod (nginx:alpine has apk).
# THE SYSCALL:  execve() of the package manager binary.
# THE RULE:     "Launch Package Management Process in Container" (default).
# WHY IT MATTERS: a package manager running in a supposedly immutable prod
#   container means someone is mutating it live — a strong drift / tampering
#   signal and a frequent step in getting attacker tooling onto a host.
set -euo pipefail

NS=demo-apps
POD=$(kubectl -n "$NS" get pod -l app=victim -o jsonpath='{.items[0].metadata.name}')

echo "[*] Running a package manager (apk) inside $POD ..."
kubectl -n "$NS" exec "$POD" -- sh -c 'apk --version && apk info >/dev/null 2>&1 || true'

echo "[✓] Done. Look for 'Package Management' (ERROR) in the Falco stream."
