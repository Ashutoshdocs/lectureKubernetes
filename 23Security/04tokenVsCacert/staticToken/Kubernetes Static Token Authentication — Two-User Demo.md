# Kubernetes Static Token Authentication — Two-User Demo

## 6. Create Static Token File

On the control-plane node:

```bash
sudo mkdir -p /etc/kubernetes/auth
```

Create the token file:

```bash
sudo tee /etc/kubernetes/auth/tokens.csv > /dev/null <<'EOF'
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
EOF
```

Secure it:

```bash
sudo chmod 600 /etc/kubernetes/auth/tokens.csv
```

Verify:

```bash
sudo cat /etc/kubernetes/auth/tokens.csv
```

Expected:

```text
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
```

---

# 7. Automatically Update kube-apiserver.yaml

Instead of manually editing:

```text
/etc/kubernetes/manifests/kube-apiserver.yaml
```

use the following script.

Create:

```bash
vi configure-static-token-auth.sh
```

Paste:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Kubernetes Static Token Authentication
# ============================================================

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUTH_DIR="/etc/kubernetes/auth"
TOKEN_FILE="${AUTH_DIR}/tokens.csv"

BACKUP=""

# ============================================================
# Cleanup / rollback
# ============================================================

rollback() {

    echo
    echo "================================================"
    echo " ERROR: Configuration failed"
    echo "================================================"

    if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then

        echo
        echo "Restoring previous API Server manifest..."

        cp -f "${BACKUP}" "${MANIFEST}"

        echo "Original manifest restored:"
        echo "  ${MANIFEST}"

        echo
        echo "Backup retained:"
        echo "  ${BACKUP}"

    else

        echo "No backup available for restoration."

    fi

    echo
    echo "The token file was not removed automatically."
    echo "Review:"
    echo "  ${TOKEN_FILE}"

    exit 1
}

trap rollback ERR

# ============================================================
# Header
# ============================================================

echo "================================================"
echo " Kubernetes Static Token Authentication"
echo "================================================"

# ============================================================
# 1. Root check
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "ERROR: This script must be run as root."
    echo
    echo "Run:"
    echo "  sudo $0"
    exit 1
fi

# ============================================================
# 2. Check API Server manifest
# ============================================================

echo
echo "[1/8] Checking API Server manifest..."

if [[ ! -f "${MANIFEST}" ]]; then
    echo
    echo "ERROR: API Server manifest not found:"
    echo "  ${MANIFEST}"
    exit 1
fi

echo "Found:"
echo "  ${MANIFEST}"

# ============================================================
# 3. Create authentication directory
# ============================================================

echo
echo "[2/8] Creating authentication directory..."

mkdir -p "${AUTH_DIR}"

# ============================================================
# 4. Create static token file
# ============================================================

echo
echo "[3/8] Creating static token file..."

cat > "${TOKEN_FILE}" <<'EOF'
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
EOF

chmod 600 "${TOKEN_FILE}"

echo "Created:"
echo "  ${TOKEN_FILE}"

# ============================================================
# 5. Backup API Server manifest
# ============================================================

echo
echo "[4/8] Creating backup..."

BACKUP="${MANIFEST}.backup.$(date +%Y%m%d-%H%M%S)"

cp -a "${MANIFEST}" "${BACKUP}"

echo "Backup created:"
echo "  ${BACKUP}"

# ============================================================
# 6. Check existing configuration
# ============================================================

echo
echo "[5/8] Checking existing configuration..."

TOKEN_ARG="--token-auth-file=${TOKEN_FILE}"

if grep -Fq -- "${TOKEN_ARG}" "${MANIFEST}"; then
    echo "token-auth-file already exists."
else
    echo "token-auth-file is not configured."
fi

if grep -Fq "name: token-auth" "${MANIFEST}"; then
    echo "token-auth volume/mount already exists."
else
    echo "token-auth volume/mount is not configured."
fi

# ============================================================
# 7. Modify API Server manifest
# ============================================================

echo
echo "[6/8] Updating API Server manifest..."

TMP_FILE="$(mktemp)"

cp "${MANIFEST}" "${TMP_FILE}"

# ------------------------------------------------------------
# Add --token-auth-file
# ------------------------------------------------------------

if ! grep -Fq -- "${TOKEN_ARG}" "${TMP_FILE}"; then

    awk -v token_arg="${TOKEN_ARG}" '
    /^    command:/ {
        print
        print "    - " token_arg
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new"

    mv "${TMP_FILE}.new" "${TMP_FILE}"

fi

# ------------------------------------------------------------
# Add volumeMount
# ------------------------------------------------------------

if ! grep -Fq "mountPath: ${AUTH_DIR}" "${TMP_FILE}"; then

    awk -v auth_dir="${AUTH_DIR}" '
    /^    volumeMounts:/ {
        print
        print "    - mountPath: " auth_dir
        print "      name: token-auth"
        print "      readOnly: true"
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new"

    mv "${TMP_FILE}.new" "${TMP_FILE}"

fi

# ------------------------------------------------------------
# Add hostPath volume
# ------------------------------------------------------------

if ! grep -Fq "path: ${AUTH_DIR}" "${TMP_FILE}"; then

    awk -v auth_dir="${AUTH_DIR}" '
    /^  volumes:/ {
        print
        print "  - hostPath:"
        print "      path: " auth_dir
        print "      type: DirectoryOrCreate"
        print "    name: token-auth"
        next
    }
    { print }
    ' "${TMP_FILE}" > "${TMP_FILE}.new"

    mv "${TMP_FILE}.new" "${TMP_FILE}"

fi

# Replace manifest only after all modifications completed.

mv "${TMP_FILE}" "${MANIFEST}"

# ============================================================
# 8. Validate configuration
# ============================================================

echo
echo "[7/8] Validating configuration..."

ERRORS=0

# ------------------------------------------------------------
# Check token argument
# ------------------------------------------------------------

if grep -Fq -- "${TOKEN_ARG}" "${MANIFEST}"; then
    echo "✓ --token-auth-file configured"
else
    echo "✗ --token-auth-file missing"
    ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------
# Check volumeMount
# ------------------------------------------------------------

if grep -Fq "mountPath: ${AUTH_DIR}" "${MANIFEST}" &&
   grep -Fq "name: token-auth" "${MANIFEST}"; then

    echo "✓ token-auth volumeMount configured"

else

    echo "✗ token-auth volumeMount missing"
    ERRORS=$((ERRORS + 1))

fi

# ------------------------------------------------------------
# Check hostPath
# ------------------------------------------------------------

if grep -Fq "path: ${AUTH_DIR}" "${MANIFEST}" &&
   grep -Fq "type: DirectoryOrCreate" "${MANIFEST}" &&
   grep -Fq "name: token-auth" "${MANIFEST}"; then

    echo "✓ token-auth hostPath configured"

else

    echo "✗ token-auth hostPath missing"
    ERRORS=$((ERRORS + 1))

fi

# ------------------------------------------------------------
# Check token file
# ------------------------------------------------------------

if [[ -s "${TOKEN_FILE}" ]]; then
    echo "✓ token file exists"
else
    echo "✗ token file missing or empty"
    ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------
# Check permissions
# ------------------------------------------------------------

PERMISSIONS="$(stat -c '%a' "${TOKEN_FILE}")"

if [[ "${PERMISSIONS}" == "600" ]]; then
    echo "✓ token file permissions are 600"
else
    echo "✗ token file permissions are ${PERMISSIONS}"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# Validation result
# ============================================================

if [[ "${ERRORS}" -ne 0 ]]; then

    echo
    echo "Validation failed."
    echo "Rollback will be performed."

    false

fi

# ============================================================
# Final output
# ============================================================

echo
echo "[8/8] Configuration validated successfully."

echo
echo "================================================"
echo " SUCCESS"
echo "================================================"

echo
echo "Token file:"
echo "  ${TOKEN_FILE}"

echo
echo "API Server manifest:"
echo "  ${MANIFEST}"

echo
echo "Backup:"
echo "  ${BACKUP}"

echo
echo "Configured argument:"
grep -F -- "${TOKEN_ARG}" "${MANIFEST}"

echo
echo "Token volume configuration:"
grep -A4 -B1 "name: token-auth" "${MANIFEST}"

echo
echo "The kubelet should detect the manifest change"
echo "and recreate the kube-apiserver static Pod."

echo
echo "Check:"
echo
echo "  kubectl get pods -n kube-system | grep kube-apiserver"

echo
echo "================================================"
```

---

# Run the Script

Make it executable:

```bash
chmod +x configure-static-token-auth.sh
```

Run:

```bash
sudo ./configure-static-token-auth.sh
```

---

# Expected Output

You should see something similar to:

```text
================================================
 Kubernetes Static Token Authentication
================================================

[1/8] Checking API Server manifest...
Found:
  /etc/kubernetes/manifests/kube-apiserver.yaml

[2/8] Creating authentication directory...

[3/8] Creating static token file...
Created:
  /etc/kubernetes/auth/tokens.csv

[4/8] Creating backup...
Backup created:
  /etc/kubernetes/manifests/kube-apiserver.yaml.backup.20260912-123000

[5/8] Checking existing configuration...
token-auth-file is not configured.
token-auth volume/mount is not configured.

[6/8] Updating API Server manifest...

[7/8] Validating configuration...
✓ --token-auth-file configured
✓ token-auth volumeMount configured
✓ token-auth hostPath configured
✓ token file exists
✓ token file permissions are 600

[8/8] Configuration validated successfully.

================================================
 SUCCESS
================================================
```

---

# 8. Run the Script

Make it executable:

```bash
chmod +x configure-static-token-auth.sh
```

Run:

```bash
sudo ./configure-static-token-auth.sh
```

---

# 9. What the Script Does

The script performs these steps:

```text
             configure-static-token-auth.sh
                         │
                         ▼
              Check root privileges
                         │
                         ▼
               Check API Server YAML
                         │
                         ▼
                Create token directory
                         │
                         ▼
                  Create tokens.csv
                         │
                         ▼
               Backup API Server YAML
                         │
                         ▼
             Add --token-auth-file
                         │
                         ▼
                Add volumeMount
                         │
                         ▼
                  Add hostPath
                         │
                         ▼
               kubelet detects change
                         │
                         ▼
                API Server restarts
```

---

# 10. Expected API Server Configuration

After the script runs, the API Server configuration should contain:

```yaml
command:
  - kube-apiserver
  - --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

and:

```yaml
volumeMounts:
  - mountPath: /etc/kubernetes/auth
    name: token-auth
    readOnly: true
```

and:

```yaml
volumes:
  - hostPath:
      path: /etc/kubernetes/auth
      type: DirectoryOrCreate
    name: token-auth
```

The important relationship is:

```text
HOST
/etc/kubernetes/auth/tokens.csv
              │
              │ hostPath
              ▼
API SERVER CONTAINER
/etc/kubernetes/auth/tokens.csv
              │
              ▼
--token-auth-file
              │
              ▼
Static Token Authentication
```

---

# 11. Verify the API Server

Check the API Server:

```bash
kubectl get pods -n kube-system | grep kube-apiserver
```

Wait until it is:

```text
Running
```

Check the argument:

```bash
kubectl -n kube-system get pod \
  -l component=kube-apiserver \
  -o yaml | grep token-auth-file
```

Expected:

```text
- --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

---

# 12. Verify the Token File

On the control-plane node:

```bash
sudo ls -l /etc/kubernetes/auth/tokens.csv
```

Expected permissions:

```text
-rw------- ...
```

Verify contents:

```bash
sudo cat /etc/kubernetes/auth/tokens.csv
```

Expected:

```text
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
```

---

# 13. Important: Do Not Run the Script Blindly

The script modifies a **critical control-plane manifest**.

Before running it in a real cluster:

```bash
sudo cp \
  /etc/kubernetes/manifests/kube-apiserver.yaml \
  /etc/kubernetes/manifests/kube-apiserver.yaml.manual-backup
```

Then inspect the resulting YAML:

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Validate that:

```text
--token-auth-file
volumeMounts
volumes
```

are correctly indented and located.

A malformed static Pod manifest can cause the API Server to fail.

For a production environment, prefer a YAML-aware editing method rather than blindly modifying YAML with `sed`.

---

# 14. Safer Alternative: Use a Dedicated Patch Script

For a kubeadm control plane, an even safer approach is to use a Python script to modify the YAML structurally.

Install PyYAML if it is not already available:

```bash
sudo apt-get update
sudo apt-get install -y python3-yaml
```

Create:

```bash
vi update-apiserver-token-auth.py
```

Use:

```python
#!/usr/bin/env python3

import shutil
from datetime import datetime
import yaml

MANIFEST = "/etc/kubernetes/manifests/kube-apiserver.yaml"
TOKEN_DIR = "/etc/kubernetes/auth"
TOKEN_FILE = f"{TOKEN_DIR}/tokens.csv"

backup = (
    MANIFEST
    + ".backup."
    + datetime.now().strftime("%Y%m%d-%H%M%S")
)

# Backup
shutil.copy2(MANIFEST, backup)

# Read YAML
with open(MANIFEST, "r") as f:
    data = yaml.safe_load(f)

container = data["spec"]["containers"][0]

# ------------------------------------------------
# Add API Server argument
# ------------------------------------------------

command = container.setdefault("command", [])

token_argument = f"--token-auth-file={TOKEN_FILE}"

command = [
    arg for arg in command
    if not arg.startswith("--token-auth-file=")
]

command.append(token_argument)

container["command"] = command

# ------------------------------------------------
# Add volume mount
# ------------------------------------------------

volume_mounts = container.setdefault("volumeMounts", [])

volume_mounts = [
    mount
    for mount in volume_mounts
    if mount.get("name") != "token-auth"
]

volume_mounts.append({
    "mountPath": TOKEN_DIR,
    "name": "token-auth",
    "readOnly": True
})

container["volumeMounts"] = volume_mounts

# ------------------------------------------------
# Add hostPath volume
# ------------------------------------------------

volumes = data["spec"].setdefault("volumes", [])

volumes = [
    volume
    for volume in volumes
    if volume.get("name") != "token-auth"
]

volumes.append({
    "name": "token-auth",
    "hostPath": {
        "path": TOKEN_DIR,
        "type": "DirectoryOrCreate"
    }
})

data["spec"]["volumes"] = volumes

# ------------------------------------------------
# Write YAML
# ------------------------------------------------

with open(MANIFEST, "w") as f:
    yaml.safe_dump(
        data,
        f,
        default_flow_style=False,
        sort_keys=False
    )

print("Configuration updated successfully.")
print(f"Backup: {backup}")
print(f"Token file: {TOKEN_FILE}")
```

Run:

```bash
sudo python3 update-apiserver-token-auth.py
```

---

# 15. Recommended Demo Sequence

For the lab, use this order:

```text
1. Create namespace
        ↓
2. Create tokens.csv
        ↓
3. Configure kube-apiserver
        ↓
4. Restart / wait for API Server
        ↓
5. Verify authentication
        ↓
6. Create Alice RBAC
        ↓
7. Create Bob RBAC
        ↓
8. Create Alice kubeconfig
        ↓
9. Test Alice
        ↓
10. Create Bob kubeconfig
        ↓
11. Test Bob
        ↓
12. Demonstrate 401 vs 403
        ↓
13. Cleanup
```

## Expected Security Demonstration

```text
Alice
  │
  │ alice-token-123
  ▼
API Server
  │
  ├── Authentication → alice ✓
  │
  └── RBAC
        │
        ├── get pods     ✓
        ├── list pods    ✓
        └── create pods  ✗
                          │
                          ▼
                     403 Forbidden


Bob
  │
  │ bob-token-456
  ▼
API Server
  │
  ├── Authentication → bob ✓
  │
  └── RBAC
        │
        ├── get pods      ✓
        ├── list pods     ✓
        ├── create pods   ✓
        └── delete pods   ✓
```

> **Important:** Static token authentication is useful for demonstrating how Kubernetes authentication works, but static bearer tokens are generally not the preferred choice for production clusters because of credential-management and rotation limitations.
