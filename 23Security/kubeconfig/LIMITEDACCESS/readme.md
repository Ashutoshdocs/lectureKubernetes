# Kubernetes PROD Logs-Only User

A helper script that provisions a **read-only, logs-only** Kubernetes user scoped to a single namespace (`prod`). It creates the RBAC objects, issues a client certificate signed by the cluster CA, and produces a ready-to-use kubeconfig the user can copy to their laptop.

The resulting user can **list pods** and **read pod logs** in the `prod` namespace — nothing else.

---

## What it does

1. Reads the API server URL from your current kubeconfig context.
2. Verifies the cluster CA cert/key and the target namespace exist.
3. Creates a namespaced `Role` (`prod-logs-reader`) granting `get`/`list` on pods and `get` on `pods/log`.
4. Binds that Role to the user via a `RoleBinding`.
5. Generates a client private key + CSR for the user (`CN=prod-logs-user`).
6. Signs the client cert with the cluster CA (valid 365 days).
7. Writes a self-contained kubeconfig (`/home/azure/prod-viewer.conf`) with certs embedded, sets ownership/permissions, and cleans up temp files.

---

## Prerequisites

- Run on a **control-plane node** (or any host that has the files below).
- `kubectl` configured with admin access to the cluster.
- `openssl` installed.
- Read access to the cluster CA:
  - `/etc/kubernetes/pki/ca.crt`
  - `/etc/kubernetes/pki/ca.key`
- An `azure` user/group present (the output file is `chown`ed to `azure:azure`).
- The `prod` namespace must already exist.

> **Note:** Signing directly with `ca.key` requires access to the cluster's private CA key, which normally lives only on control-plane nodes. On managed clusters (AKS/EKS/GKE) that key is not exposed — see [Managed clusters](#managed-clusters-aks--eks--gke) below.

---

## Configuration

Edit these variables at the top of the script if needed:

| Variable     | Default                       | Description                          |
|--------------|-------------------------------|--------------------------------------|
| `USERNAME`   | `prod-logs-user`              | Kubernetes user (cert `CN`)          |
| `NAMESPACE`  | `prod`                        | Namespace the user is scoped to      |
| `CA_CERT`    | `/etc/kubernetes/pki/ca.crt`  | Cluster CA certificate               |
| `CA_KEY`     | `/etc/kubernetes/pki/ca.key`  | Cluster CA private key               |
| `OUTPUT`     | `/home/azure/prod-viewer.conf`| Generated kubeconfig path            |

`API_SERVER` is detected automatically from the current context.

---

## Usage

```bash
chmod +x setup-prod-logs-user.sh
sudo ./setup-prod-logs-user.sh
```

`sudo` is generally required to read `ca.key` and to `chown` the output file.

On success the script prints the kubeconfig path and copy/test instructions.

---

## Distributing the kubeconfig

From your laptop:

```bash
scp azure@<PUBLIC-IP>:/home/azure/prod-viewer.conf ./prod-viewer.conf
```

Test it:

```bash
kubectl --kubeconfig=./prod-viewer.conf get pods -n prod
kubectl --kubeconfig=./prod-viewer.conf logs <pod> -n prod
```

Confirm the boundaries are enforced (these should be **denied**):

```bash
kubectl --kubeconfig=./prod-viewer.conf get pods -n default        # forbidden
kubectl --kubeconfig=./prod-viewer.conf delete pod <pod> -n prod   # forbidden
kubectl --kubeconfig=./prod-viewer.conf get secrets -n prod        # forbidden
```

---

## What gets created

**In the cluster**

- `Role/prod-logs-reader` in namespace `prod`
- `RoleBinding/prod-logs-reader-binding` in namespace `prod`

**On disk**

- `/home/azure/prod-viewer.conf` — the kubeconfig (owner `azure:azure`, mode `600`)

Temporary key/cert/CSR files in `/tmp` are removed at the end.

---

## Permissions granted

| Resource    | Verbs        |
|-------------|--------------|
| `pods`      | `get`, `list`|
| `pods/log`  | `get`        |

Deliberately excludes `exec`, `delete`, `secrets`, `create`, and any cluster-scoped access.

---

## Security notes

- The generated kubeconfig embeds a **client private key** — treat the file as a credential. It is written `600` and owned by `azure`.
- The client certificate is valid for **365 days**. There is no built-in revocation for client certs in Kubernetes short of rotating the CA, so plan re-issuance and avoid over-long lifetimes for sensitive access.
- The script uses `-CAcreateserial`, which writes `ca.crt.srl` next to the CA cert; the script removes it afterward.
- Client-cert auth cannot be revoked individually. For environments that need revocation, prefer short-lived tokens, OIDC, or the Kubernetes CSR API instead of hand-signing.

---

## Managed clusters (AKS / EKS / GKE)

Managed control planes do **not** give you `ca.key`, so the direct `openssl x509 -CA ... -CAkey ...` signing step will fail. Alternatives:

- Use the **Kubernetes CertificateSigningRequest API** (`kubectl certificate approve`) so the cluster signs the cert for you.
- Use the provider's IAM/OIDC integration (Azure AD, IAM roles, Workload Identity) and bind RBAC to those identities.
- Use a **ServiceAccount token** bound to the same Role if a human-user identity isn't required.

The `Role`/`RoleBinding` portion of this script is portable; only the certificate-signing step is control-plane-specific.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `CA private key not found` | Not on a control-plane node, or key path differs. |
| `Namespace 'prod' does not exist` | Create it: `kubectl create namespace prod`. |
| `Forbidden` on valid commands | RoleBinding subject name must match the cert `CN` exactly. |
| `x509: certificate signed by unknown authority` | Wrong CA embedded, or API server uses a different CA. |
| Permission denied writing output | Run with `sudo`; ensure the `azure` user exists. |

---

## Cleanup

```bash
kubectl delete rolebinding prod-logs-reader-binding -n prod
kubectl delete role prod-logs-reader -n prod
rm -f /home/azure/prod-viewer.conf
```
