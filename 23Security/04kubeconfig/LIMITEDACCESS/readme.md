# Kubernetes Namespace-Scoped User Provisioning

Two helper scripts that provision **certificate-authenticated Kubernetes users** scoped to a single namespace. Each script creates the RBAC objects, issues a client certificate signed by the cluster CA, and produces a ready-to-use kubeconfig the user can copy to their laptop.

| Script | User | Namespace | Access level |
|--------|------|-----------|--------------|
| `setup-prod-logs-user.sh` | `prod-logs-user` | `prod` | Read-only: list pods, read pod logs |
| `setup-dev-admin-user.sh` | `dev-admin-user` | `dev` | Full admin **within the namespace** (`*/*/*`) |

Both scripts share the same mechanics and differ only in the **Role** they create.

---

## How the two roles differ

**Prod (logs-only)** grants the minimum needed to view logs:

| Resource   | Verbs         |
|------------|---------------|
| `pods`     | `get`, `list` |
| `pods/log` | `get`         |

No `exec`, no `secrets`, no writes.

**Dev (namespace admin)** grants everything *inside* the `dev` namespace:

```yaml
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
```

Because it's a `Role` (namespaced) and not a `ClusterRole`, this power stops at the `dev` namespace boundary. The user can create/delete/edit any namespaced resource in `dev` — including **secrets** and **service accounts** — but has no access to other namespaces or cluster-scoped resources.

> The `dev-admin` user can read every secret in `dev` and create workloads. Keep it out of any namespace that shares nodes or secrets with production, and don't reuse it for `prod`.

---

## What each script does

1. Reads the API server URL from your current kubeconfig context.
2. Verifies the cluster CA cert/key and the target namespace exist.
3. Creates a namespaced `Role` (logs-reader or namespace-admin).
4. Binds that Role to the user via a `RoleBinding`.
5. Generates a client private key + CSR (`CN=<username>`).
6. Signs the client cert with the cluster CA (valid 365 days).
7. Writes a self-contained kubeconfig with certs embedded, sets ownership/permissions, and cleans up temp files.

The `CN` in the certificate is the identity Kubernetes authenticates; the `RoleBinding` subject name **must match that `CN` exactly** or requests will be forbidden.

---

## Prerequisites

- Run on a **control-plane node** (or any host with the files below).
- `kubectl` configured with admin access to the cluster.
- `openssl` installed.
- Read access to the cluster CA:
  - `/etc/kubernetes/pki/ca.crt`
  - `/etc/kubernetes/pki/ca.key`
- An `azure` user/group present (output files are `chown`ed to `azure:azure`).
- The target namespace (`prod` or `dev`) must already exist.

> **Managed clusters (AKS / EKS / GKE):** the direct `openssl ... -CAkey ca.key` signing step will fail because the CA private key isn't exposed. Use the Kubernetes CSR API (`kubectl certificate approve`) or the provider's IAM/OIDC integration instead. The `Role`/`RoleBinding` portion is portable; only the signing step is control-plane-specific.

---

## Configuration

Editable variables at the top of each script:

| Variable    | Prod default                    | Dev default                   |
|-------------|---------------------------------|-------------------------------|
| `USERNAME`  | `prod-logs-user`                | `dev-admin-user`              |
| `NAMESPACE` | `prod`                          | `dev`                         |
| `CA_CERT`   | `/etc/kubernetes/pki/ca.crt`    | same                          |
| `CA_KEY`    | `/etc/kubernetes/pki/ca.key`    | same                          |
| `OUTPUT`    | `/home/azure/prod-viewer.conf`  | `/home/azure/dev-admin.conf`  |

`API_SERVER` is detected automatically from the current context.

---

## Usage

```bash
# Prod logs-only viewer
chmod +x setup-prod-logs-user.sh
sudo ./setup-prod-logs-user.sh

# Dev namespace admin
chmod +x setup-dev-admin-user.sh
sudo ./setup-dev-admin-user.sh
```

`sudo` is generally required to read `ca.key` and to `chown` the output file.

---

## Distributing the kubeconfig

From your laptop:

```bash
scp azure@<PUBLIC-IP>:/home/azure/prod-viewer.conf ./prod-viewer.conf
scp azure@<PUBLIC-IP>:/home/azure/dev-admin.conf   ./dev-admin.conf
```

---

## Testing

**Prod (should succeed):**

```bash
kubectl --kubeconfig=./prod-viewer.conf get pods -n prod
kubectl --kubeconfig=./prod-viewer.conf logs <pod> -n prod
```

**Prod (should be forbidden):**

```bash
kubectl --kubeconfig=./prod-viewer.conf delete pod <pod> -n prod
kubectl --kubeconfig=./prod-viewer.conf get secrets -n prod
kubectl --kubeconfig=./prod-viewer.conf get pods -n dev
```

**Dev (should succeed):**

```bash
kubectl --kubeconfig=./dev-admin.conf get pods -n dev
kubectl --kubeconfig=./dev-admin.conf create deployment nginx --image=nginx -n dev
```

**Dev (should be forbidden — proves the namespace boundary holds):**

```bash
kubectl --kubeconfig=./dev-admin.conf get pods -n prod
kubectl --kubeconfig=./dev-admin.conf get nodes            # cluster-scoped
kubectl --kubeconfig=./dev-admin.conf get namespaces       # cluster-scoped
```

---

## What gets created

**In the cluster**

| Script | Objects |
|--------|---------|
| Prod   | `Role/prod-logs-reader`, `RoleBinding/prod-logs-reader-binding` (ns `prod`) |
| Dev    | `Role/dev-admin`, `RoleBinding/dev-admin-binding` (ns `dev`) |

**On disk**

- `/home/azure/prod-viewer.conf` and/or `/home/azure/dev-admin.conf` — kubeconfigs (owner `azure:azure`, mode `600`)

Temp key/cert/CSR files in `/tmp` are removed at the end of each run.

---

## Security notes

- Each kubeconfig embeds a **client private key** — treat the file as a credential. It's written `600` and owned by `azure`.
- Client certificates are valid **365 days**. Kubernetes has **no per-certificate revocation** short of rotating the CA, so keep lifetimes conservative and plan re-issuance. For anything needing revocation, prefer short-lived tokens, OIDC, or the CSR API over hand-signed certs.
- `-CAcreateserial` writes `ca.crt.srl` next to the CA cert; the scripts remove it afterward.
- The `dev-admin` role is powerful within its namespace. Namespaced admin still means full read/write of that namespace's secrets — scope which namespace it targets carefully and never point it at `prod`.
- Keep the two identities separate. Don't bind `dev-admin-user` in `prod` or widen the prod role for convenience.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `CA private key not found` | Not on a control-plane node, or the key path differs (managed cluster). |
| `Namespace '...' does not exist` | Create it: `kubectl create namespace <name>`. |
| `Forbidden` on commands that should work | RoleBinding subject name must match the cert `CN` exactly. |
| `x509: certificate signed by unknown authority` | Wrong CA embedded, or the API server uses a different CA. |
| Dev user can't touch nodes/namespaces | Expected — it's a namespaced `Role`, not a `ClusterRole`. |
| Permission denied writing output | Run with `sudo`; ensure the `azure` user exists. |

---

## Cleanup

```bash
# Prod
kubectl delete rolebinding prod-logs-reader-binding -n prod
kubectl delete role prod-logs-reader -n prod
rm -f /home/azure/prod-viewer.conf

# Dev
kubectl delete rolebinding dev-admin-binding -n dev
kubectl delete role dev-admin -n dev
rm -f /home/azure/dev-admin.conf
```
