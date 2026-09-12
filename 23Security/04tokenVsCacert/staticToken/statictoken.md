# Kubernetes Static Token Authentication — Two-User Demo (alice & bob)

This walkthrough configures the `kube-apiserver` for static bearer-token
authentication and demonstrates RBAC with two users:

- **alice** — read-only pods (gets a **403** when she tries to create)
- **bob** — full pod management (create/delete allowed)

> **Why the old script failed:** the original `awk` block matched
> `/^    command:/` (four spaces, no dash). A real kubeadm manifest indents
> the command with two spaces and a dash (`  - command:`), so the pattern
> never matched, `--token-auth-file` was never added, validation failed, and
> the `ERR` trap rolled everything back — on every run. Both the bash script
> below (regex fixed) and the Python script are corrected here.

---

## Prerequisites

- A kubeadm control-plane node with `/etc/kubernetes/manifests/kube-apiserver.yaml`
- `root` / `sudo` access on the control-plane node
- `kubectl` with admin access (the default `/etc/kubernetes/admin.conf`)

---

## Step 1 — Create the demo namespace

```bash
kubectl create namespace demo
```

---

## Step 2 — Create the static token file

Format is: `token,username,uid,"group1,group2"`

```bash
sudo mkdir -p /etc/kubernetes/auth

sudo tee /etc/kubernetes/auth/tokens.csv > /dev/null <<'EOF'
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
EOF

sudo chmod 600 /etc/kubernetes/auth/tokens.csv
sudo cat /etc/kubernetes/auth/tokens.csv
```

Expected:

```text
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
```

---

## Step 3 — Configure the kube-apiserver

You are editing a **critical control-plane manifest**. A malformed file will
stop the API server from starting. Two methods are given below.

### Option A — Python (recommended, structural edit)

This edits the YAML by parsing it, so indentation can't break. It is also
idempotent (re-running won't create duplicate entries).

Install PyYAML if needed:

```bash
sudo apt-get update
sudo apt-get install -y python3-yaml
```

Create `update-apiserver-token-auth.py`:

```python
#!/usr/bin/env python3

import shutil
from datetime import datetime
import yaml

MANIFEST = "/etc/kubernetes/manifests/kube-apiserver.yaml"
TOKEN_DIR = "/etc/kubernetes/auth"
TOKEN_FILE = f"{TOKEN_DIR}/tokens.csv"

backup = MANIFEST + ".backup." + datetime.now().strftime("%Y%m%d-%H%M%S")
shutil.copy2(MANIFEST, backup)

with open(MANIFEST) as f:
    data = yaml.safe_load(f)

container = data["spec"]["containers"][0]

# --- API server argument (dedup, then add) ---
command = container.setdefault("command", [])
command = [a for a in command if not a.startswith("--token-auth-file=")]
command.append(f"--token-auth-file={TOKEN_FILE}")
container["command"] = command

# --- volumeMount ---
mounts = container.setdefault("volumeMounts", [])
mounts = [m for m in mounts if m.get("name") != "token-auth"]
mounts.append({"mountPath": TOKEN_DIR, "name": "token-auth", "readOnly": True})
container["volumeMounts"] = mounts

# --- hostPath volume ---
volumes = data["spec"].setdefault("volumes", [])
volumes = [v for v in volumes if v.get("name") != "token-auth"]
volumes.append({
    "name": "token-auth",
    "hostPath": {"path": TOKEN_DIR, "type": "DirectoryOrCreate"},
})
data["spec"]["volumes"] = volumes

with open(MANIFEST, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)

print("Configuration updated successfully.")
print(f"Backup: {backup}")
print(f"Token file: {TOKEN_FILE}")
```

Run it:

```bash
sudo python3 update-apiserver-token-auth.py
```

### Option B — Bash (fixed regex)

The only functional change from the original is the `command:` match line,
which now matches the real `  - command:` layout.

Create `configure-static-token-auth.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUTH_DIR="/etc/kubernetes/auth"
TOKEN_FILE="${AUTH_DIR}/tokens.csv"
BACKUP=""

rollback() {
    echo
    echo "ERROR: Configuration failed."
    if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then
        cp -f "${BACKUP}" "${MANIFEST}"
        echo "Restored manifest from ${BACKUP}"
    else
        echo "No backup available for restoration."
    fi
    echo "Token file left in place: ${TOKEN_FILE}"
    exit 1
}
trap rollback ERR

# 1. Root check
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo $0)"
    exit 1
fi

# 2. Manifest present?
echo "[1/8] Checking API Server manifest..."
[[ -f "${MANIFEST}" ]] || { echo "ERROR: not found: ${MANIFEST}"; exit 1; }

# 3. Auth dir
echo "[2/8] Creating authentication directory..."
mkdir -p "${AUTH_DIR}"

# 4. Token file
echo "[3/8] Creating static token file..."
cat > "${TOKEN_FILE}" <<'EOF'
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
EOF
chmod 600 "${TOKEN_FILE}"

# 5. Backup
echo "[4/8] Creating backup..."
BACKUP="${MANIFEST}.backup.$(date +%Y%m%d-%H%M%S)"
cp -a "${MANIFEST}" "${BACKUP}"
echo "Backup: ${BACKUP}"

# 6. Inspect current state
echo "[5/8] Checking existing configuration..."
TOKEN_ARG="--token-auth-file=${TOKEN_FILE}"
grep -Fq -- "${TOKEN_ARG}" "${MANIFEST}" \
    && echo "token-auth-file already present." \
    || echo "token-auth-file not configured."

# 7. Modify (work on a temp copy)
echo "[6/8] Updating API Server manifest..."
TMP_FILE="$(mktemp)"
cp "${MANIFEST}" "${TMP_FILE}"

# Add --token-auth-file  (FIX: match "  - command:" not "    command:")
if ! grep -Fq -- "${TOKEN_ARG}" "${TMP_FILE}"; then
    awk -v token_arg="${TOKEN_ARG}" '
    /^[[:space:]]*- command:[[:space:]]*$/ {
        print
        print "    - " token_arg
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new" && mv "${TMP_FILE}.new" "${TMP_FILE}"
fi

# Add volumeMount
if ! grep -Fq "mountPath: ${AUTH_DIR}" "${TMP_FILE}"; then
    awk -v auth_dir="${AUTH_DIR}" '
    /^[[:space:]]*volumeMounts:[[:space:]]*$/ {
        print
        print "    - mountPath: " auth_dir
        print "      name: token-auth"
        print "      readOnly: true"
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new" && mv "${TMP_FILE}.new" "${TMP_FILE}"
fi

# Add hostPath volume
if ! grep -Fq "path: ${AUTH_DIR}" "${TMP_FILE}"; then
    awk -v auth_dir="${AUTH_DIR}" '
    /^[[:space:]]*volumes:[[:space:]]*$/ {
        print
        print "  - hostPath:"
        print "      path: " auth_dir
        print "      type: DirectoryOrCreate"
        print "    name: token-auth"
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new" && mv "${TMP_FILE}.new" "${TMP_FILE}"
fi

mv "${TMP_FILE}" "${MANIFEST}"

# 8. Validate
echo "[7/8] Validating configuration..."
ERRORS=0
grep -Fq -- "${TOKEN_ARG}" "${MANIFEST}"          && echo "✓ --token-auth-file"      || { echo "✗ --token-auth-file"; ERRORS=$((ERRORS+1)); }
grep -Fq "mountPath: ${AUTH_DIR}" "${MANIFEST}"   && echo "✓ volumeMount"            || { echo "✗ volumeMount"; ERRORS=$((ERRORS+1)); }
grep -Fq "path: ${AUTH_DIR}" "${MANIFEST}"        && echo "✓ hostPath"               || { echo "✗ hostPath"; ERRORS=$((ERRORS+1)); }
[[ -s "${TOKEN_FILE}" ]]                          && echo "✓ token file"             || { echo "✗ token file"; ERRORS=$((ERRORS+1)); }
[[ "$(stat -c '%a' "${TOKEN_FILE}")" == "600" ]]  && echo "✓ permissions 600"        || { echo "✗ permissions"; ERRORS=$((ERRORS+1)); }

[[ "${ERRORS}" -eq 0 ]] || { echo "Validation failed — rolling back."; false; }

echo "[8/8] Success. The kubelet will recreate the kube-apiserver static Pod."
echo "Backup kept at: ${BACKUP}"
```

Run it:

```bash
chmod +x configure-static-token-auth.sh
sudo ./configure-static-token-auth.sh
```

---

## Step 4 — Verify the API server restarted

The kubelet detects the manifest change and recreates the static Pod. Give it
30–60 seconds.

```bash
kubectl get pods -n kube-system | grep kube-apiserver
```

Wait for `Running`. Then confirm the flag:

```bash
kubectl -n kube-system get pod -l component=kube-apiserver -o yaml \
  | grep token-auth-file
```

Expected:

```text
- --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

If the Pod does **not** come back, inspect the container logs directly (kubectl
may be unavailable while the API server is down):

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs <container-id>
```

Restore the backup if needed:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.backup.* \
        /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Step 5 — Create RBAC for alice and bob

alice gets read-only pods; bob gets full pod management. Both scoped to the
`demo` namespace.

```bash
kubectl apply -f - <<'EOF'
# alice: read-only pods
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: demo
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: demo
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
---
# bob: full pod management
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: demo
  name: pod-admin
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bob-pod-admin
  namespace: demo
subjects:
- kind: User
  name: bob
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

---

## Step 6 — Build kubeconfigs for each user

Set the control-plane endpoint once:

```bash
CP_IP="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "${CP_IP}"   # e.g. https://10.0.0.1:6443
```

alice:

```bash
kubectl config set-cluster demo-cluster \
  --server="${CP_IP}" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig

kubectl config set-credentials alice \
  --token=alice-token-123 \
  --kubeconfig=alice.kubeconfig

kubectl config set-context alice@demo \
  --cluster=demo-cluster --user=alice --namespace=demo \
  --kubeconfig=alice.kubeconfig

kubectl config use-context alice@demo --kubeconfig=alice.kubeconfig
```

bob (same, swapping name/token):

```bash
kubectl config set-cluster demo-cluster \
  --server="${CP_IP}" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=bob.kubeconfig

kubectl config set-credentials bob \
  --token=bob-token-456 \
  --kubeconfig=bob.kubeconfig

kubectl config set-context bob@demo \
  --cluster=demo-cluster --user=bob --namespace=demo \
  --kubeconfig=bob.kubeconfig

kubectl config use-context bob@demo --kubeconfig=bob.kubeconfig
```

---

## Step 7 — Test authentication and RBAC (401 vs 403)

**alice — can read, cannot create:**

```bash
kubectl --kubeconfig=alice.kubeconfig get pods            # ✓ allowed
kubectl --kubeconfig=alice.kubeconfig run nginx --image=nginx   # ✗ 403 Forbidden
```

**bob — can read and create:**

```bash
kubectl --kubeconfig=bob.kubeconfig get pods              # ✓ allowed
kubectl --kubeconfig=bob.kubeconfig run nginx --image=nginx     # ✓ allowed
kubectl --kubeconfig=bob.kubeconfig delete pod nginx     # ✓ allowed
```

**401 vs 403 — the key distinction:**

```bash
# Bad/absent token -> authentication fails -> 401 Unauthorized
kubectl --server="${CP_IP}" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --token=not-a-real-token get pods
# error: ... Unauthorized (401)

# Valid token, insufficient RBAC -> 403 Forbidden (alice creating a pod above)
```

- **401** = the API server doesn't know who you are (authentication).
- **403** = it knows who you are, but you're not allowed (authorization / RBAC).

---

## Cleanup

```bash
kubectl delete namespace demo
rm -f alice.kubeconfig bob.kubeconfig

# Remove the token flag: restore the backup, or delete the three added blocks
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.backup.* \
        /etc/kubernetes/manifests/kube-apiserver.yaml
sudo rm -f /etc/kubernetes/auth/tokens.csv
```

---

## Production note

Static token authentication is great for **learning how Kubernetes auth
works**, but static bearer tokens are not recommended for production: they
don't expire, can't be rotated without editing the file and restarting the API
server, and are stored in plaintext. For real clusters prefer OIDC, client
certificates with short lifetimes, or a cloud provider IAM integration.
