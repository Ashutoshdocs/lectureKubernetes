# Securing Kubernetes Secrets — from plain YAML to Azure Key Vault

A hands-on demo built around a tiny app: **one frontend Deployment** and **one
SQL Deployment**, where the sensitive value is the **SQL `sa` password**.

It walks through the problem you described — *"if the password is in a YAML file
on the node, or pushed to a GitHub repo, anyone can read it"* — and then shows
**four progressively stronger fixes**, ending with **Azure Key Vault**.

| Stage | Folder | What it does | Safe in Git? | Safe in etcd? | Secret leaves cluster? |
|------|--------|--------------|:---:|:---:|:---:|
| 00 | `manifests/00-insecure` | Password hard-coded in the Deployment YAML | ❌ | ❌ | — |
| 01 | `manifests/01-native-secret` | Move it into a native `Secret` (base64) | ⚠️ no | ❌ | — |
| 02 | `manifests/02-sealed-secrets` | Encrypt it so you *can* commit to GitHub | ✅ | ❌* | — |
| 03 | `manifests/03-encryption-at-rest` | Encrypt Secrets inside etcd | ✅ | ✅ | — |
| 04 | `manifests/04-azure-key-vault` | Store it in Azure Key Vault, outside the cluster | ✅ | ✅ | ✅ |

`*` Sealed Secrets protects Git; combine it with stage 03 to also protect etcd.

> **The key idea:** base64 is **encoding, not encryption**. A native Kubernetes
> Secret keeps the password out of the Deployment, but anyone with
> `kubectl get secret ... -o yaml` + `base64 -d`, or read access to etcd, or your
> Git repo, can still recover it. Each stage closes one of those holes.

---

## Prerequisites

- A Kubernetes cluster (`kind`, `minikube`, or AKS) and `kubectl`.
- For stage 02: `helm` + the `kubeseal` CLI.
- For stage 04: an **AKS** cluster, the `az` CLI (logged in), and `helm`.

---

## 🔴 Stage 00 — Demonstrate the problem

The password is written in plain text inside the Deployment.

```bash
kubectl apply -f manifests/00-insecure/
```

Now **prove the leak** — this is exactly what an attacker (or anyone with repo
or node access) can do:

```bash
# The password is visible in the live object...
kubectl get deploy sql -o yaml | grep -A1 MSSQL_SA_PASSWORD

# ...and it's sitting in plain text in the YAML file on disk / in Git:
grep -r "P@ssw0rd" manifests/00-insecure/
```

You will see `P@ssw0rd-VERY-INSECURE-123` in clear text. If this file is pushed
to GitHub, the secret is leaked to everyone with read access — **and stays in
git history forever**, even if you delete it later.

Clean up before the next stage:

```bash
kubectl delete -f manifests/00-insecure/
```

---

## 🟠 Stage 01 — Native Kubernetes Secret

Move the password out of the Deployment into a `Secret`, referenced with
`secretKeyRef`.

**Best practice: create the Secret imperatively so the value never touches a
file** (do NOT commit it):

```bash
kubectl create secret generic sql-secret \
  --from-literal=MSSQL_SA_PASSWORD='P@ssw0rd-VERY-INSECURE-123'
```

(The included `sql-secret.yaml` shows the object for learning purposes — but do
not commit a file that contains the value.)

Then apply the deployments, which now pull the password from the Secret:

```bash
kubectl apply -f manifests/01-native-secret/sql-deployment.yaml
kubectl apply -f manifests/01-native-secret/frontend-deployment.yaml
```

✅ The Deployment YAMLs are now safe to commit.
⚠️ **But the Secret itself is only base64-encoded**, not encrypted:

```bash
kubectl get secret sql-secret -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 -d
# -> prints the password. base64 is NOT security.
```

That is the hole the next stages close.

---

## 🟡 Stage 02 — Sealed Secrets (safe to push to GitHub)

A **SealedSecret** is encrypted with the cluster controller's *public* key. Only
the controller (with the private key) can decrypt it, so the file is safe to
commit to a public repo.

```bash
# 1. Install the controller (once per cluster)
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# 2. Install the kubeseal CLI (macOS example)
brew install kubeseal

# 3. Seal your secret -> produces committable ciphertext
kubectl create secret generic sql-secret \
  --from-literal=MSSQL_SA_PASSWORD='P@ssw0rd-VERY-INSECURE-123' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --format yaml \
  > manifests/02-sealed-secrets/sql-sealedsecret.yaml

# 4. Apply. The controller decrypts it into a normal `sql-secret`.
kubectl apply -f manifests/02-sealed-secrets/sql-sealedsecret.yaml
kubectl get secret sql-secret   # created automatically by the controller
```

Then reuse the stage-01 deployments (they just consume `sql-secret`):

```bash
kubectl apply -f manifests/01-native-secret/sql-deployment.yaml
kubectl apply -f manifests/01-native-secret/frontend-deployment.yaml
```

✅ You can now commit `sql-sealedsecret.yaml` to GitHub safely.
The `encryptedData` in the sample file is a **placeholder** — regenerate it
against your own cluster with the command above (ciphertext is cluster-specific).

---

## 🟢 Stage 03 — Encryption at rest (etcd)

Even with a native Secret, Kubernetes stores it **unencrypted in etcd** by
default. Anyone who can read etcd on a control-plane node — or steal an etcd
backup — reads every secret. This stage encrypts Secrets before they hit etcd.

**Self-managed clusters** (you control the control plane):

```bash
# 1. Generate a 32-byte key and paste it into encryption-config.yaml
head -c 32 /dev/urandom | base64

# 2. Copy the file onto each control-plane node
sudo cp manifests/03-encryption-at-rest/encryption-config.yaml \
  /etc/kubernetes/enc/encryption-config.yaml

# 3. Add this flag to /etc/kubernetes/manifests/kube-apiserver.yaml and mount
#    the file, then let the apiserver restart:
#    --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml

# 4. Re-encrypt all existing secrets
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Managed clusters (AKS):** you don't touch the apiserver flags. Enable
**KMS etcd encryption backed by Azure Key Vault**:

```bash
az aks update -g <RG> -n <AKS> \
  --enable-azure-keyvault-kms \
  --azure-keyvault-kms-key-id "<KEY_VAULT_KEY_URI>"
```

✅ Secrets are now encrypted at rest in etcd.

---

## 🔵 Stage 04 — Azure Key Vault (recommended) ⭐

The strongest option: the password lives in **Azure Key Vault, outside the
cluster**. It is never in any YAML, never in Git, never in etcd. The
**Secrets Store CSI Driver** fetches it at pod start using the pod's **Azure
Workload Identity**, and mirrors it into a normal `sql-secret` for env-var use.

### Step 1 — Run the setup (creates Key Vault, identity, federation)

Edit the variables at the top of the script, then:

```bash
bash manifests/04-azure-key-vault/setup-azure.sh
```

It prints the four values you need (`clientID`, `keyvaultName`, `tenantId`,
`objectName`). What it does under the hood:

1. Creates a Key Vault and stores the password as a secret named `sql-password`.
2. Enables the `azure-keyvault-secrets-provider` addon (the CSI driver) and
   Workload Identity + OIDC issuer on AKS.
3. Creates a user-assigned managed identity and grants it
   **Key Vault Secrets User**.
4. Federates that identity to the `workload-identity-sa` ServiceAccount.

### Step 2 — Fill in the placeholders

Put the printed values into:
- `manifests/04-azure-key-vault/secretproviderclass.yaml`
  (`clientID`, `keyvaultName`, `tenantId`)
- the `azure.workload.identity/client-id` annotation on the ServiceAccount in
  `sql-deployment.yaml`

### Step 3 — Deploy

```bash
kubectl apply -f manifests/04-azure-key-vault/secretproviderclass.yaml
kubectl apply -f manifests/04-azure-key-vault/sql-deployment.yaml
kubectl apply -f manifests/04-azure-key-vault/frontend-deployment.yaml
```

### Step 4 — Verify

```bash
# The CSI driver created the Secret from Key Vault automatically:
kubectl get secret sql-secret -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 -d

# The pod also has it mounted as a file:
kubectl exec deploy/sql -- cat /mnt/secrets-store/sql-password
```

To **rotate** the password, just update it in Key Vault:

```bash
az keyvault secret set --vault-name <KV> -n sql-password --value 'NewStr0ng!Pass'
```

The CSI driver picks up the new version (rotation polling is enabled on the
addon), and no YAML changes or re-commits are ever required.

✅ Secret out of Git, out of etcd, out of the cluster — centrally managed,
audited, and rotatable in Azure Key Vault.

---

## Why Key Vault is the best of the four

- **Nothing sensitive in Git** — only a `SecretProviderClass` that names *where*
  the secret is, never the value.
- **Nothing sensitive in etcd** — the value is pulled at runtime (and you can
  still layer stage 03 on top).
- **Central management** — rotation, expiry, access policies, and a full audit
  log live in Azure, not scattered across manifests.
- **Least privilege** — Workload Identity means only pods using that specific
  ServiceAccount can read that specific secret; no cluster-wide credentials.

## Cleanup

```bash
kubectl delete -f manifests/04-azure-key-vault/ --ignore-not-found
kubectl delete secret sql-secret --ignore-not-found
# az group delete -n rg-k8s-secret-demo   # removes the Key Vault + identity
```
