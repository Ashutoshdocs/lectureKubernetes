# ServiceAccount demo: MySQL → backup Job → Azure Storage

A hands-on lab that teaches Kubernetes **ServiceAccounts** with a real, verifiable
"it fails without the right permissions, it works with them" scenario.

You get a MySQL database, a web frontend to add data, a backup **Job** that pushes a
dump to an Azure **Storage Account**, and a separate MySQL pod to restore into so you
can *prove* the backup is good. All Services are **NodePort**.

---

## Read this first: is this correct logic to demo a ServiceAccount?

Your idea — *"without a ServiceAccount the Job can't push to storage, with one it can"* —
is the right instinct, but the usual way people build it is **technically wrong**. Here's
the correction, because understanding it *is* the lesson.

**What a ServiceAccount actually is.** It is the identity a pod presents to the
**Kubernetes API server**. Every pod already runs as *some* ServiceAccount — if you don't
set one, it's the namespace's `default`. So "a pod with no ServiceAccount" doesn't exist.
What varies is **RBAC**: the Roles/RoleBindings attached to that ServiceAccount, which
decide what it may do against the API.

**The common mistake.** People wire up a demo like: *"the storage key is in a Secret; the
Job can't read the Secret without a ServiceAccount."* That is **false**. A Secret consumed
through `env` (`secretKeyRef`) or a mounted volume is delivered by the **kubelet**, not
through the API, and needs **no** ServiceAccount permission at all. If you build the demo
that way, swapping ServiceAccounts changes nothing, and the demo proves nothing.

**Where a ServiceAccount genuinely decides the outcome.** Only when the pod talks to the
**Kubernetes API** (or to a cloud IAM system federated to the SA — see "Real Azure" below).
So this lab makes the gated action a real API call: the backup Job asks the API server for
the `azure-storage-cred` Secret **over HTTPS using its ServiceAccount token**. RBAC either
allows that call or returns `403 Forbidden`.

- `default` ServiceAccount → no Role → API returns **403** → the Job **fails**.
- `backup-sa` ServiceAccount → bound to a Role allowing `get` on that Secret → **200** →
  the Job dumps the DB and uploads it.

That is a correct, honest ServiceAccount demo: the **only** thing that changes between the
failing run and the succeeding run is `serviceAccountName`, and the difference is real.

> Note: fetching the credential over the API is slightly contrived — a normal backup Job
> would just mount the Secret and skip the API entirely (and thus wouldn't need any special
> SA). We fetch it over the API *on purpose*, so the ServiceAccount is the deciding factor.
> This is the standard way to teach the concept.

---

## Architecture

```
                         NodePort 30808
   Browser ─────────────► Adminer (frontend) ──► MySQL (appdb) ◄── NodePort 30306
   (add rows)                                        │
                                                     │ mysqldump
                                                     ▼
                                   ┌─────────────────────────────────┐
                                   │  backup Job                      │
                                   │  1. ask K8s API for the secret   │ ◄─ RBAC GATE
                                   │     (uses ServiceAccount token)  │    (SA decides)
                                   │  2. mysqldump appdb              │
                                   │  3. PUT dump → Azure Blob (SAS)  │
                                   └─────────────────────────────────┘
                                                     │
                                                     ▼
                                        Azure Storage Account (backups/)
                                                     │  download blob
                                                     ▼
                                   restore-mysql pod ◄── NodePort 30307
                                   (restore + verify the backup)
```

---

## Files

| File | What it creates |
|------|-----------------|
| `00-namespace.yaml` | `sa-demo` namespace |
| `01-mysql.yaml` | MySQL Secret + init table + Deployment + NodePort `30306` |
| `02-frontend-adminer.yaml` | Adminer frontend + NodePort `30808` |
| `03-azure-storage-secret.yaml` | Secret holding the Azure **SAS URL** (edit this) |
| `04-serviceaccount-rbac.yaml` | `backup-sa` ServiceAccount + Role + RoleBinding |
| `05-backup-script-configmap.yaml` | The backup script, shared by both Jobs |
| `06-backup-job-no-sa.yaml` | Backup Job on `default` SA → **fails** |
| `07-backup-job-with-sa.yaml` | Backup Job on `backup-sa` → **succeeds** |
| `08-restore-mysql.yaml` | Throwaway MySQL pod + NodePort `30307` to verify the backup |

---

## Prerequisites

- A Kubernetes cluster and `kubectl`.
- An Azure Storage Account with a container named `backups` and a **container SAS URL**
  (`03-azure-storage-secret.yaml` explains how to generate one). The backup upload step
  needs this; everything up to and including the RBAC 403/200 demo works without it.
- Cluster nodes able to reach the internet (to pull images, `microdnf install curl`, and
  reach `*.blob.core.windows.net`).

---

## Step 1 — Namespace, database, frontend

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-mysql.yaml
kubectl apply -f 02-frontend-adminer.yaml

# wait for MySQL to be ready
kubectl -n sa-demo rollout status deploy/mysql
kubectl -n sa-demo get pods
```

---

## Step 2 — Add data from the frontend

Open Adminer in a browser at `http://<node-ip>:30808`.

- On minikube: `minikube service adminer -n sa-demo --url`
- Find a node IP: `kubectl get nodes -o wide`

Log in with:

| Field | Value |
|-------|-------|
| System | MySQL |
| Server | `mysql` |
| Username | `root` |
| Password | `RootPass123!` |
| Database | `appdb` |

Open the `messages` table → **Insert** → add a couple of rows (e.g. `content = hello world`).
You'll see the seed row from `init.sql` already there.

---

## Step 3 — Verify the data in the source MySQL pod

```bash
# Grab the MySQL pod name
MYSQL_POD=$(kubectl -n sa-demo get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}')

# List rows
kubectl -n sa-demo exec "$MYSQL_POD" -- \
  mysql -uroot -p'RootPass123!' -e "SELECT * FROM appdb.messages;"

# Count rows (remember this number to compare after restore)
kubectl -n sa-demo exec "$MYSQL_POD" -- \
  mysql -uroot -p'RootPass123!' -e "SELECT COUNT(*) AS total FROM appdb.messages;"
```

You can also connect over the NodePort from your machine (needs a local mysql client):

```bash
mysql -h <node-ip> -P 30306 -uroot -p'RootPass123!' -e "SELECT * FROM appdb.messages;"
```

---

## Step 4 — Create the ServiceAccount, RBAC, storage secret, and script

```bash
# EDIT 03-azure-storage-secret.yaml first: paste your real container SAS URL.
kubectl apply -f 03-azure-storage-secret.yaml
kubectl apply -f 04-serviceaccount-rbac.yaml
kubectl apply -f 05-backup-script-configmap.yaml
```

Confirm what each ServiceAccount is *allowed* to do (this predicts the demo result):

```bash
# default SA: expect "no"
kubectl -n sa-demo auth can-i get secret/azure-storage-cred \
  --as=system:serviceaccount:sa-demo:default

# backup-sa: expect "yes"
kubectl -n sa-demo auth can-i get secret/azure-storage-cred \
  --as=system:serviceaccount:sa-demo:backup-sa
```

---

## Step 5 — Demo the FAILURE (no permissions)

```bash
kubectl apply -f 06-backup-job-no-sa.yaml
kubectl -n sa-demo wait --for=condition=failed job/mysql-backup-no-sa --timeout=120s
kubectl -n sa-demo logs job/mysql-backup-no-sa
```

Expected: the log shows the API call returning **HTTP 403** and the script aborting before
any dump or upload. The `default` ServiceAccount has a valid token but no RBAC, so the API
refuses. **The backup is impossible.**

---

## Step 6 — Demo the SUCCESS (with the ServiceAccount)

```bash
kubectl apply -f 07-backup-job-with-sa.yaml
kubectl -n sa-demo wait --for=condition=complete job/mysql-backup-with-sa --timeout=180s
kubectl -n sa-demo logs job/mysql-backup-with-sa
```

Expected: the API call returns **HTTP 200**, the script runs `mysqldump`, and uploads
`appdb-<timestamp>.sql` to your Storage Account. The log ends with `SUCCESS`.

The **only** difference between Step 5 and Step 6 is `serviceAccountName`. That is the whole
point of the lab.

Confirm the blob landed:

```bash
az storage blob list --account-name <acct> --container-name backups \
  --prefix appdb- --auth-mode login -o table
```

---

## Step 7 — Restore into a fresh MySQL pod to prove the backup

```bash
kubectl apply -f 08-restore-mysql.yaml
kubectl -n sa-demo wait --for=condition=ready pod/restore-mysql --timeout=120s
```

Download the backup you just uploaded, then stream it into the restore pod:

```bash
# Pick the newest backup blob name from Step 6's log or the `az` list above:
BLOB=appdb-<timestamp>.sql

# Download it locally using the same SAS (base + ?token). Example:
curl -o "$BLOB" "https://<acct>.blob.core.windows.net/backups/$BLOB?<sas-token>"

# Restore into the throwaway pod via stdin
kubectl -n sa-demo exec -i restore-mysql -- \
  mysql -uroot -p'RestorePass123!' < "$BLOB"
```

---

## Step 8 — Verify the restored data matches

```bash
# Rows now present in the RESTORE pod (came only from the backup)
kubectl -n sa-demo exec restore-mysql -- \
  mysql -uroot -p'RestorePass123!' -e "SELECT * FROM appdb.messages;"

# Count — should equal the count you saw in Step 3
kubectl -n sa-demo exec restore-mysql -- \
  mysql -uroot -p'RestorePass123!' -e "SELECT COUNT(*) AS total FROM appdb.messages;"
```

If the counts and rows match the source from Step 3, the backup taken by the
ServiceAccount-authorized Job is proven correct.

---

## How the ServiceAccount gates this (deep dive)

When the Job's pod starts, Kubernetes mounts a projected token at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. The script sends it as a
`Bearer` token to `https://kubernetes.default.svc`. The API server:

1. **Authenticates** the token → identifies the caller as
   `system:serviceaccount:sa-demo:<name>`.
2. **Authorizes** via RBAC → is there a (Cluster)Role bound to that SA allowing
   `get secrets/azure-storage-cred` in `sa-demo`?

For `default` the answer is no → `403`. For `backup-sa` the RoleBinding says yes → `200`.

Two things learners should take away:

- A token by itself grants nothing; **RBAC** is what authorizes actions.
- ServiceAccounts matter for **API access**, not for consuming mounted Secrets/ConfigMaps.

---

## Real Azure: Workload Identity (the production-correct SA use)

In production you would **not** ship a SAS URL in a Secret. You'd use **Azure AD Workload
Identity**, which is the other legitimate way a ServiceAccount changes what's possible —
this time against Azure, not the K8s API. You annotate the ServiceAccount with an Azure
client ID and federate it with a Managed Identity:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-sa
  namespace: sa-demo
  annotations:
    azure.workload.identity/client-id: "<managed-identity-client-id>"
```

The pod then exchanges its projected SA token for an Azure AD token and writes to Blob
Storage with **no stored keys**. Same principle as this lab — the ServiceAccount is the
identity that unlocks access — applied to cloud IAM. It needs AKS + Azure setup, so this
lab uses the SAS approach to stay self-contained.

---

## Cleanup

```bash
kubectl delete namespace sa-demo
```

---

## Quick apply (everything at once)

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-mysql.yaml -f 02-frontend-adminer.yaml
# edit 03 first!
kubectl apply -f 03-azure-storage-secret.yaml -f 04-serviceaccount-rbac.yaml -f 05-backup-script-configmap.yaml
# run the two demo jobs in order and read their logs
kubectl apply -f 06-backup-job-no-sa.yaml     # fails
kubectl apply -f 07-backup-job-with-sa.yaml   # succeeds
kubectl apply -f 08-restore-mysql.yaml
```

## Troubleshooting

- **Backup Job can't install curl / no internet**: pre-bake an image with `mysql`,
  `curl`, and `coreutils`, and set it as the Job image instead of `mysql:8.0`.
- **`mysqldump` auth error**: MySQL 8 uses `caching_sha2_password`; the bundled MySQL 8
  client handles it, so keep the Job on the `mysql:8.0` image (don't swap in a MariaDB
  client).
- **403 on the *with-sa* Job**: re-check that `04-serviceaccount-rbac.yaml` applied and that
  `kubectl -n sa-demo auth can-i get secret/azure-storage-cred --as=system:serviceaccount:sa-demo:backup-sa`
  prints `yes`.
- **Upload 403 from Azure**: the SAS token lacks permissions or expired — regenerate with
  `--permissions rwlac` and a future `--expiry`.
