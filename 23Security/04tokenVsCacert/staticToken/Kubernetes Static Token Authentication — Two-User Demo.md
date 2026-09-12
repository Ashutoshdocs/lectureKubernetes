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

set -euo pipefail

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
TOKEN_DIR="/etc/kubernetes/auth"
TOKEN_FILE="${TOKEN_DIR}/tokens.csv"

echo "=============================================="
echo " Kubernetes Static Token Authentication Setup"
echo "=============================================="

# ------------------------------------------------
# 1. Check root privileges
# ------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example:"
    echo "  sudo $0"
    exit 1
fi

# ------------------------------------------------
# 2. Check kube-apiserver manifest
# ------------------------------------------------

if [[ ! -f "${MANIFEST}" ]]; then
    echo "ERROR: kube-apiserver manifest not found:"
    echo "  ${MANIFEST}"
    exit 1
fi

# ------------------------------------------------
# 3. Create authentication directory
# ------------------------------------------------

echo
echo "[1/6] Creating token authentication directory..."

mkdir -p "${TOKEN_DIR}"

# ------------------------------------------------
# 4. Create token file
# ------------------------------------------------

echo "[2/6] Creating static token file..."

cat > "${TOKEN_FILE}" <<'EOF'
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
EOF

chmod 600 "${TOKEN_FILE}"

echo "Token file created:"
echo "  ${TOKEN_FILE}"

# ------------------------------------------------
# 5. Backup API Server manifest
# ------------------------------------------------

BACKUP="${MANIFEST}.backup.$(date +%Y%m%d-%H%M%S)"

echo
echo "[3/6] Creating API Server manifest backup..."

cp "${MANIFEST}" "${BACKUP}"

echo "Backup:"
echo "  ${BACKUP}"

# ------------------------------------------------
# 6. Update API Server command
# ------------------------------------------------

echo
echo "[4/6] Updating kube-apiserver command..."

if grep -q -- "--token-auth-file=" "${MANIFEST}"; then

    echo "Existing --token-auth-file found."

    sed -i \
      "s|^[[:space:]]*-[[:space:]]*--token-auth-file=.*|    - --token-auth-file=${TOKEN_FILE}|" \
      "${MANIFEST}"

else

    echo "Adding --token-auth-file..."

    sed -i \
      "/^[[:space:]]*command:/a\    - --token-auth-file=${TOKEN_FILE}" \
      "${MANIFEST}"

fi

# ------------------------------------------------
# 7. Add volumeMount
# ------------------------------------------------

echo
echo "[5/6] Adding token directory volume mount..."

if grep -q "name: token-auth" "${MANIFEST}"; then

    echo "token-auth volume already exists."

else

    # Add volumeMount immediately after the existing
    # volumeMounts section.
    sed -i \
      "/^[[:space:]]*volumeMounts:/a\    - mountPath: ${TOKEN_DIR}\n      name: token-auth\n      readOnly: true" \
      "${MANIFEST}"

    # Add hostPath volume.
    cat >> /dev/null <<EOF
EOF

    # Insert volume before the first existing volume entry.
    sed -i \
      "/^[[:space:]]*volumes:/a\  - hostPath:\n      path: ${TOKEN_DIR}\n      type: DirectoryOrCreate\n    name: token-auth" \
      "${MANIFEST}"

fi

# ------------------------------------------------
# 8. Display configuration
# ------------------------------------------------

echo
echo "[6/6] Verifying configuration..."

echo
echo "Token authentication argument:"
grep -- "--token-auth-file=" "${MANIFEST}" || true

echo
echo "Token volume:"
grep -A4 -B1 "name: token-auth" "${MANIFEST}" || true

echo
echo "=============================================="
echo " Configuration Complete"
echo "=============================================="

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
echo "Kubelet should detect the manifest change and"
echo "restart the kube-apiserver static Pod."

echo
echo "Check with:"
echo
echo "  kubectl get pods -n kube-system | grep kube-apiserver"
echo
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
