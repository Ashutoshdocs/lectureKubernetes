# PostgreSQL Primary → Replica Failover on AKS (with PV Access Modes)

A hands-on demo on **Azure Kubernetes Service**:

- A **frontend** (2 pods) exposed to the internet by a **LoadBalancer Service**
- **2 PostgreSQL pods**: `pg-a-0` = **primary** (all writes), `pg-b-0` = **replica** (streams data from the primary)
- You **break the primary for real**, **promote the replica**, **prove the switch**, then **repair the old primary** as the new replica
- Storage teaches **PV access modes**: Azure Disk `ReadWriteOnce` for each DB, Azure Files `ReadWriteMany` shared by the frontends, plus a dedicated lab for RWO / RWOP / RWX

**Duration:** ~2 hours including cluster creation · **Cost:** 3 × Standard_D2s_v5 nodes + 2 small disks + 1 file share + 1 public IP. **Delete the resource group when done** (Part 10).

---

## Architecture

```
                        Internet
                           │
                 ┌─────────▼──────────┐
                 │ Service: frontend  │  type: LoadBalancer  (Azure public IP, port 80)
                 └─────────┬──────────┘
              ┌────────────┴────────────┐
        ┌─────▼─────┐             ┌─────▼─────┐
        │ frontend  │             │ frontend  │   Deployment, 2 replicas
        │  pod #1   │             │  pod #2   │
        └──┬────┬───┘             └──┬────┬───┘
           │    └──── /shared ───────┘    │       PVC frontend-shared
           │       Azure Files  RWX       │       (azurefile-csi, ReadWriteMany)
   WRITES  │                              │ READS
  ┌────────▼─────────┐          ┌─────────▼────────┐
  │ Svc: pg-primary  │          │ Svc: pg-replica  │   ClusterIP; failover = change selector
  │ selector pg-a    │          │ selector pg-b    │
  └────────┬─────────┘          └─────────┬────────┘
     ┌─────▼──────┐   streaming     ┌─────▼──────┐
     │  pg-a-0    │ ──── WAL ─────► │  pg-b-0    │   2 StatefulSets (1 pod each)
     │  PRIMARY   │  replication    │  REPLICA   │   on DIFFERENT nodes (anti-affinity)
     └─────┬──────┘                 └─────┬──────┘
     Azure Disk RWO                 Azure Disk RWO     PVC data-pg-a-0 / data-pg-b-0
     (managed-csi)                  (managed-csi)      (ReadWriteOnce)

  ConfigMap pg-cluster: PRIMARY_INSTANCE=pg-a   ← single source of truth for "who is primary"
```

### How the roles work (the key idea)

Each DB pod runs `start.sh` (in ConfigMap `pg-scripts`) **before** Postgres starts:

| Situation at pod start | What `start.sh` does |
|---|---|
| I am `PRIMARY_INSTANCE`, disk empty | Official entrypoint runs `initdb` + `01-init.sh` (creates `replicator` role and `messages` table) |
| I am `PRIMARY_INSTANCE`, disk has data | Start Postgres normally |
| I am the replica, disk empty | `pg_basebackup` from Service `pg-primary` with `-R` → writes `standby.signal` → starts as a streaming replica |
| I am the replica, disk has replica data | Start as standby |
| I am the replica, disk has **old primary** data (no `standby.signal`) | **Wipe & re-clone** from the current primary (this is how the broken primary gets fixed) |

Every row records **which DB pod wrote it** (`written_on`, the column default is `current_setting('cluster_name')`, set to the pod name). Before failover, rows say `pg-a-0`; after failover, they say `pg-b-0`. **That is the proof.**

---

## Files

```
pg-failover-aks/
├── README.md
├── k8s/
│   ├── 00-namespace.yaml          # namespace pg-demo
│   ├── 01-secret.yaml             # postgres + replication passwords (demo only)
│   ├── 02-configmaps.yaml         # pg-cluster (who is primary) + pg-scripts (start.sh, 01-init.sh)
│   ├── 03-services.yaml           # pg-headless, pg-primary, pg-replica
│   ├── 10-pg-statefulsets.yaml    # pg-a and pg-b, Azure Disk RWO via volumeClaimTemplates
│   ├── 20-frontend.yaml           # Flask app, Azure Files RWX PVC, Deployment, LoadBalancer
│   └── 30-access-modes-lab.yaml   # RWO / RWOP / RWX / wrong-combination lab
└── scripts/
    ├── 00-create-aks.sh           # creates RG + AKS + kubeconfig
    ├── status.sh                  # who is primary? who streams from whom?
    ├── write-loop.sh              # 1 write/second through the LoadBalancer
    ├── break-primary.sh           # breaks the current primary for real
    ├── failover.sh                # automated version of Part 6 + 7
    └── 99-cleanup.sh              # deletes the resource group
```

---

## Part 0 — Concepts to explain first (10 min)

**Streaming replication:** the primary writes every change to its WAL (write-ahead log). The replica connects as user `replicator`, receives WAL continuously and replays it. The replica is **read-only** (`pg_is_in_recovery() = true`).

**Failover** = making the replica the new primary: `SELECT pg_promote();`. Postgres then leaves recovery, starts a **new timeline** (1 → 2) and accepts writes.

**Fencing:** before promoting, make sure the old primary **cannot come back** as a second primary. Two primaries means **split brain** (two diverging copies of the data). In this demo, fencing = `kubectl scale sts pg-a --replicas=0`.

**This demo is manual on purpose**, so students see each step. In production use an operator that does all of this automatically: **CloudNativePG**, **Patroni / Zalando postgres-operator**, **Crunchy PGO**, or the managed **Azure Database for PostgreSQL Flexible Server** with zone-redundant HA.

### PV access modes

| Mode | Short | Meaning | Azure Disk (`managed-csi`) | Azure Files (`azurefile-csi`) | Used here by |
|---|---|---|---|---|---|
| ReadWriteOnce | RWO | read-write by **one node** (several pods on that node may share it) | ✅ | ✅ | each Postgres pod |
| ReadOnlyMany | ROX | read-only by many nodes | ⚠️ limited | ✅ | — |
| ReadWriteMany | RWX | read-write by **many nodes** at once | ❌ (filesystem mode) | ✅ | frontend shared log |
| ReadWriteOncePod | RWOP | read-write by **exactly one pod** in the whole cluster | ✅ | ✅ | lab only |

**Why the database uses RWO disks and not one shared RWX volume:** two Postgres servers must never write the same data files. Replication copies data **over the network**; each instance owns its own disk. Azure Disk is block storage with low latency, which is right for a database. Azure Files (SMB/NFS) is shared storage, which is right for shared app files, and wrong for Postgres data.

---

## Part 1 — Set up the AKS cluster (15 min)

### 1.1 Install tools

```bash
# Azure CLI  (https://learn.microsoft.com/cli/azure/install-azure-cli)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash      # Ubuntu/Debian
az version

# kubectl (via Azure CLI)
sudo az aks install-cli
kubectl version --client
```

> Or use **Azure Cloud Shell** (shell.azure.com), which has both tools preinstalled.

### 1.2 Log in and choose a subscription

```bash
az login
az account list -o table
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
```

### 1.3 Create the cluster

Option A — one script:

```bash
chmod +x scripts/*.sh
./scripts/00-create-aks.sh          # defaults: centralindia, 3 x Standard_D2s_v5
```

Option B — commands step by step:

```bash
export RG=rg-pg-failover-demo
export LOCATION=centralindia        # pick a region close to you
export CLUSTER=aks-pg-failover

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.Network --wait

az group create --name $RG --location $LOCATION

az aks create \
  --resource-group $RG \
  --name $CLUSTER \
  --location $LOCATION \
  --tier free \
  --node-count 3 \
  --node-vm-size Standard_D2s_v5 \
  --enable-managed-identity \
  --generate-ssh-keys

az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing
```

> **3 nodes** are needed: the two DB pods have required anti-affinity (different nodes), and the access-modes lab spreads pods across nodes. If `Standard_D2s_v5` is unavailable or over quota in your region, check `az vm list-skus -l $LOCATION --size Standard_D -o table` and pick another 2-vCPU size.

### 1.4 Verify the cluster and its storage classes

```bash
kubectl get nodes -o wide
kubectl get storageclass
```

Expected (names matter, details vary):

```
NAME                    PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE
azurefile-csi           file.csi.azure.com   Delete          Immediate
azurefile-csi-premium   file.csi.azure.com   Delete          Immediate
managed-csi (default)   disk.csi.azure.com   Delete          WaitForFirstConsumer
managed-csi-premium     disk.csi.azure.com   Delete          WaitForFirstConsumer
```

**Teaching point:** `managed-csi` = Azure Disk (RWO), `azurefile-csi` = Azure Files (RWX). `WaitForFirstConsumer` means the disk is created only when a pod is scheduled, in that node's zone.

---

## Part 2 — Deploy the databases (10 min)

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secret.yaml
kubectl apply -f k8s/02-configmaps.yaml
kubectl apply -f k8s/03-services.yaml
kubectl apply -f k8s/10-pg-statefulsets.yaml

kubectl config set-context --current --namespace=pg-demo
kubectl get pods -l app=pg -o wide -w          # Ctrl+C when both are 1/1 Running
```

`pg-b-0` waits for `pg-primary` and then clones itself. Watch it:

```bash
kubectl logs pg-a-0 | grep start.sh
kubectl logs pg-b-0 | grep -E 'start.sh|streaming'
```

Expected:

```
[start.sh 10:04:28] ROLE = REPLICA of pg-a
[start.sh 10:04:28] Cloning with pg_basebackup from pg-primary ...
[start.sh 10:04:29] Clone complete. standby.signal + primary_conninfo written by -R.
... LOG:  started streaming WAL from primary at 0/3000000 on timeline 1
```

### 2.1 Show the PVCs, PVs and Azure Disks (access modes)

```bash
kubectl get pvc -o custom-columns=PVC:.metadata.name,STATUS:.status.phase,MODES:.spec.accessModes,CLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage

kubectl get pv -o custom-columns=PV:.metadata.name,CLAIM:.spec.claimRef.name,MODES:.spec.accessModes,RECLAIM:.spec.persistentVolumeReclaimPolicy

kubectl get volumeattachments -o custom-columns=PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName,ATTACHED:.status.attached

# The real Azure Disks live in the AKS-managed "MC_" resource group:
az disk list -g $(az aks show -g $RG -n $CLUSTER --query nodeResourceGroup -o tsv) -o table
```

**Teaching point:** each RWO disk is attached to exactly **one node** (see `volumeattachments`).

---

## Part 3 — Deploy the frontend behind a LoadBalancer (10 min)

```bash
kubectl apply -f k8s/20-frontend.yaml
kubectl get pods -l app=frontend -o wide       # wait for 1/1 Running (~30-60 s, it pip-installs Flask)
kubectl get svc frontend -w                    # wait for EXTERNAL-IP (1-3 min)
```

```bash
export FRONTEND_IP=$(kubectl get svc frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open http://$FRONTEND_IP/?auto=1"
```

**Teaching point:** `type: LoadBalancer` makes AKS create a public IP + Azure Load Balancer rule in the `MC_` resource group:

```bash
az network public-ip list -g $(az aks show -g $RG -n $CLUSTER --query nodeResourceGroup -o tsv) -o table
```

### Frontend endpoints

| Endpoint | What it does |
|---|---|
| `GET /` (`/?auto=1` refreshes every 3 s) | Web page: status of both DB services, latest rows, shared log |
| `POST /api/write` `{"body":"..."}` | Insert a row via **pg-primary** |
| `GET /api/status` | JSON: which pod is behind each Service, its role, row count, streaming replicas |
| `GET /api/messages?limit=10` | Latest rows, read from **pg-replica** (falls back to primary) |
| `GET /api/shared-log` | Last lines of the RWX shared log |

---

## Part 4 — Prove replication is working (10 min)

### 4.1 Write through the frontend

```bash
for m in hello from before-failover; do
  curl -s -X POST http://$FRONTEND_IP/api/write -H 'Content-Type: application/json' -d "{\"body\":\"$m\"}"; echo
done
```

Expected: `"written_on":"pg-a-0"` on every row.

### 4.2 The replica has the same data

```bash
kubectl exec pg-b-0 -- psql -U postgres -d appdb -c "SELECT id, body, written_on FROM messages ORDER BY id;"
kubectl exec pg-b-0 -- psql -U postgres -Atc "SELECT pg_is_in_recovery();"      # t = replica
```

### 4.3 The primary sees the replica streaming

```bash
kubectl exec pg-a-0 -- psql -U postgres -c "SELECT application_name, state, sync_state, client_addr FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state | client_addr
------------------+-----------+------------+-------------
 pg-b-0           | streaming | async      | 10.244.x.x
```

### 4.4 The replica refuses writes

```bash
kubectl exec pg-b-0 -- psql -U postgres -d appdb -c "INSERT INTO messages(body) VALUES ('x');"
# ERROR:  cannot execute INSERT in a read-only transaction
```

### 4.5 One command for everything

```bash
./scripts/status.sh
```

```
=== ConfigMap pg-cluster: PRIMARY_INSTANCE = pg-a
=== Service selectors -> endpoints
  pg-primary  selector instance=pg-a  endpoints: pg-a-0(10.244.1.12)
  pg-replica  selector instance=pg-b  endpoints: pg-b-0(10.244.2.9)
--- pg-a-0: PRIMARY | timeline=1 | rows=3 | last: 3 | before-failover | written_on=pg-a-0
    pg_stat_replication (replicas streaming from me):
      pg-b-0  state=streaming  sync=async  client=10.244.2.9
--- pg-b-0: REPLICA (in recovery) | timeline=1 | rows=3 | last: 3 | before-failover | written_on=pg-a-0
    receiving WAL from: pg-primary  status=streaming
```

---

## Part 5 — BREAK the primary (5 min)

Open **3 terminals**:

| Terminal | Command |
|---|---|
| T1 | `./scripts/write-loop.sh` (one write per second, shows the outage live) |
| T2 | `kubectl get pods -l app=pg -w` |
| T3 | run the commands below |

Also keep the browser on `http://$FRONTEND_IP/?auto=1`.

### The break command

```bash
kubectl exec pg-a-0 -- bash -c 'mv "$PGDATA/global/pg_control" "$PGDATA/global/pg_control.broken" && kill -QUIT 1'
```

(or `./scripts/break-primary.sh`, which does the same thing to whichever pod is currently primary)

What it does:
1. Hides `global/pg_control`, the file Postgres needs to start. This simulates disk corruption.
2. `kill -QUIT 1` sends SIGQUIT to PID 1 (postgres), which is an **immediate shutdown**, i.e. a crash.

Kubernetes restarts the container, Postgres **cannot start**, and the pod goes into **CrashLoopBackOff**. Restarting does not fix it. That makes this a real outage, not just a pod that heals itself.

### Observe the outage

```bash
kubectl get pods -l app=pg                    # pg-a-0  0/1  CrashLoopBackOff
kubectl logs pg-a-0 | tail -3
#   postgres: could not find the database system
#   ... could not open file ".../global/pg_control": No such file or directory

kubectl get endpoints pg-primary              # <none> -> no ready primary
curl -s http://$FRONTEND_IP/api/status | python3 -m json.tool
```

- **T1 (write-loop):** `{"ok":false,"error":"connection failed ..."}` → **writes are down**
- **Browser:** `pg-primary` card is red **DOWN**. Rows still show, **read from pg-replica**, because reads keep working.
- `kubectl logs pg-b-0 --tail=2` shows the replica can't reach the primary: `could not connect to the primary server`

---

## Part 6 — FAILOVER: promote the replica (10 min)

Do this manually first so every step is visible. (`./scripts/failover.sh` automates Parts 6 and 7.)

### 6.1 Fence the old primary (prevents split brain)

```bash
kubectl scale statefulset pg-a --replicas=0
kubectl get pods -l app=pg                    # pg-a-0 is gone
```

> **Why first?** If `pg-a-0` were somehow repaired and restarted as primary while `pg-b-0` is also primary, clients could write to both and the data would diverge. Always fence before promoting.

### 6.2 Promote the replica

```bash
kubectl exec pg-b-0 -- psql -U postgres -c "SELECT pg_promote(wait => true);"
#  pg_promote
# ------------
#  t

kubectl exec pg-b-0 -- psql -U postgres -Atc "SELECT pg_is_in_recovery();"
# f      <- it is now a PRIMARY

kubectl logs pg-b-0 | grep -E 'promote|timeline|ready to accept'
#   LOG:  received promote request
#   LOG:  selected new timeline ID: 2
#   LOG:  database system is ready to accept connections
```

### 6.3 Record the new primary in the ConfigMap

```bash
kubectl patch configmap pg-cluster --type merge -p '{"data":{"PRIMARY_INSTANCE":"pg-b"}}'
kubectl get configmap pg-cluster -o jsonpath='{.data.PRIMARY_INSTANCE}'; echo     # pg-b
```

### 6.4 Repoint the Services (the actual traffic switch)

```bash
kubectl patch service pg-primary --type merge -p '{"spec":{"selector":{"app":"pg","instance":"pg-b"}}}'
kubectl patch service pg-replica --type merge -p '{"spec":{"selector":{"app":"pg","instance":"pg-a"}}}'

kubectl get endpoints pg-primary pg-replica
# pg-primary   10.244.2.9:5432     <- pg-b-0
# pg-replica   <none>              <- pg-a is fenced; fixed in Part 7
```

**Teaching point:** the frontend never changed. It always writes to the DNS name `pg-primary`. Failover just changed **which pod is behind that Service**.

### 6.5 PROVE the switch

```bash
# 1. Writes work again (T1 recovers by itself) and are written by pg-b-0
curl -s -X POST http://$FRONTEND_IP/api/write -H 'Content-Type: application/json' -d '{"body":"after-failover"}'; echo
# {"ok":true,"id":34,"written_on":"pg-b-0", ...}

# 2. Old rows (written by pg-a-0) AND new rows (written by pg-b-0) are all on the new primary -> no data loss
kubectl exec pg-b-0 -- psql -U postgres -d appdb -c "SELECT written_on, count(*), min(id), max(id) FROM messages GROUP BY written_on;"
#  written_on | count | min | max
# ------------+-------+-----+-----
#  pg-a-0     |     3 |   1 |   3
#  pg-b-0     |     1 |  34 |  34

# 3. Timeline changed 1 -> 2
kubectl exec pg-b-0 -- psql -U postgres -Atc "SELECT timeline_id FROM pg_control_checkpoint();"

# 4. Full picture
./scripts/status.sh
```

In **T1** (write-loop), point out the **exact outage window**: the first failed write and the first `"ok":true` with `"written_on":"pg-b-0"`. That gap is your **RTO** (recovery time objective) for manual failover.

> **Why did `id` jump from 3 to 34?** Postgres pre-allocates sequence values in batches of 32 in the WAL. After a promotion, the new primary continues from the end of the last logged batch. Gaps in serial IDs are normal. Never rely on IDs being contiguous.

> **Async replication caveat:** this demo uses async replication. Any transaction committed on the old primary in the last moment before the crash that had not yet streamed to the replica is lost (RPO > 0). For zero data loss use `synchronous_standby_names` (sync replication), at the cost of write latency.

---

## Part 7 — FIX the old primary and bring it back as the replica (10 min)

The old primary's disk is broken **and** on the old timeline (1). It must become a replica of `pg-b-0`.

```bash
kubectl scale statefulset pg-a --replicas=1
kubectl get pods -l app=pg -w                  # pg-a-0 -> 1/1 Running
```

`start.sh` sees the ConfigMap now says `PRIMARY_INSTANCE=pg-b`, finds old primary data (no `standby.signal`), **wipes it** (including the broken `pg_control`), and re-clones from the new primary:

```bash
kubectl logs pg-a-0 | grep -E 'start.sh|timeline'
```

```
[start.sh 10:05:02] ROLE = REPLICA of pg-b
[start.sh 10:05:02] Found data from a FORMER PRIMARY (no standby.signal). It may have diverged.
[start.sh 10:05:02] Wiping the disk and re-cloning from the current primary.
[start.sh 10:05:02] Cloning with pg_basebackup from pg-primary ...
[start.sh 10:05:02] Clone complete. standby.signal + primary_conninfo written by -R.
... LOG:  started streaming WAL from primary at 0/5000000 on timeline 2
```

### 7.1 PROVE the repair

```bash
# pg-a-0 is now a REPLICA
kubectl exec pg-a-0 -- psql -U postgres -Atc "SELECT pg_is_in_recovery();"           # t

# The NEW primary sees pg-a-0 streaming from it
kubectl exec pg-b-0 -- psql -U postgres -c "SELECT application_name, state FROM pg_stat_replication;"
#  pg-a-0 | streaming

# pg-a-0 has ALL rows, including those written by pg-b-0 while it was down
kubectl exec pg-a-0 -- psql -U postgres -d appdb -c "SELECT id, body, written_on FROM messages ORDER BY id;"

# Same PVC / same Azure Disk as before -> RWO disk re-attached, data replaced by a fresh clone
kubectl get pvc data-pg-a-0
kubectl get endpoints pg-replica                                                    # pg-a-0 again
./scripts/status.sh
```

Browser: both cards are green, `pg-primary` → **pg-b-0 PRIMARY**, `pg-replica` → **pg-a-0 REPLICA**.

> **Production note:** wiping and re-cloning is simple and always correct, but slow for big databases. `pg_rewind` can resync a diverged old primary by copying only the changed blocks. It needs `wal_log_hints=on`, which is already enabled in this demo, or data checksums.

---

## Part 8 — (Optional) Fail back to pg-a with the script (5 min)

Run the whole cycle again in the other direction, fully automated:

```bash
./scripts/break-primary.sh       # breaks pg-b-0 (the current primary), Ctrl+C after CrashLoopBackOff
./scripts/failover.sh            # fence pg-b -> promote pg-a -> ConfigMap -> Services -> rebuild pg-b
./scripts/status.sh
```

Rows written now show `written_on = pg-a-0` again, and the timeline becomes 3.

---

## Part 9 — PV Access Modes lab (20 min)

```bash
kubectl apply -f k8s/30-access-modes-lab.yaml
kubectl -n access-lab get pods -o wide -w        # wait ~1-2 min
kubectl -n access-lab get pvc
```

### A) ReadWriteOnce = one **node**

```bash
kubectl -n access-lab get pods -l app=rwo-test -o wide
# one Running, one stuck in ContainerCreating (on a DIFFERENT node)

kubectl -n access-lab describe pod -l app=rwo-test | grep -A3 -i 'multi-attach'
# Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) rwo-test-...
```

**Teaching point:** RWO is about **nodes**, not pods. Remove the anti-affinity so both pods land on the same node, and both would run.

### B) ReadWriteOncePod = one **pod**

```bash
kubectl -n access-lab get pods -l app=rwop-test -o wide
# one Running, one Pending
kubectl -n access-lab describe pod -l app=rwop-test | grep -A3 -i 'events' | tail -3
# the scheduler explains the PVC is already in use by a pod with ReadWriteOncePod access
```

**Teaching point:** RWOP is stricter than RWO. It is a good fit for a single-writer database volume.

### C) ReadWriteMany = many nodes

```bash
kubectl -n access-lab get pods -l app=rwx-test -o wide        # both Running, on different nodes
POD=$(kubectl -n access-lab get pod -l app=rwx-test -o jsonpath='{.items[0].metadata.name}')
kubectl -n access-lab exec $POD -- tail -6 /data/log.txt
# lines from BOTH pods, from BOTH nodes, in one file
```

The same thing is happening in the real app: both frontend pods append to one Azure Files share.

```bash
curl -s http://$FRONTEND_IP/api/shared-log | python3 -m json.tool
# lines from frontend-xxxxx-aaaa AND frontend-xxxxx-bbbb
kubectl -n pg-demo get pods -l app=frontend -o wide            # different nodes
```

### D) Wrong combination: RWX on Azure Disk

```bash
kubectl -n access-lab get pvc disk-rwx-wrong                  # Pending forever
kubectl -n access-lab describe pvc disk-rwx-wrong | tail -5   # ProvisioningFailed: access mode not supported
kubectl -n access-lab get pod disk-rwx-consumer               # Pending
```

**Teaching point:** the access mode must be supported by the storage backend. Azure Disk is block storage (one node). For shared read-write, use Azure Files (or Azure NetApp Files / Blob NFS).

### Clean up the lab

```bash
kubectl delete -f k8s/30-access-modes-lab.yaml
```

---

## Part 10 — Cleanup (do not skip, it costs money)

```bash
kubectl delete namespace pg-demo          # deletes PVCs -> Azure Disks + File share (reclaimPolicy: Delete)
./scripts/99-cleanup.sh                   # az group delete --name rg-pg-failover-demo --yes --no-wait
```

Deleting the resource group also deletes the AKS-managed `MC_...` group (VMs, disks, public IP, load balancer).

---

## Quiz / discussion

1. Why must you fence the old primary **before** promoting the replica? *(split brain)*
2. The frontend config never changed during failover. Why did writes move to pg-b-0? *(the pg-primary Service selector changed)*
3. Why does each Postgres pod get its own RWO disk instead of sharing one RWX volume? *(two servers must never write the same data files; replication copies data over the network)*
4. An RWO volume is mounted by pod X on node 1. Can pod Y on node 1 mount it? On node 2? *(node 1 yes, node 2 no: Multi-Attach)*
5. What is the difference between RWO and RWOP? *(node vs pod)*
6. Why can't the old primary just restart as a replica with its old data? *(it may contain transactions the new primary never got, on the old timeline; it must be re-cloned or pg_rewind-ed)*
7. How would you get zero data loss on failover? *(synchronous replication)*
8. What would CloudNativePG / Patroni do for you here? *(health checks, automatic fencing + promotion, Service switch, rebuild, backups)*

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `pg-b-0` log loops `waiting for service pg-primary` | Primary not Ready yet. Check `kubectl logs pg-a-0` and `kubectl get endpoints pg-primary` |
| DB pod `Pending`, event `didn't match pod anti-affinity` | Fewer than 2 nodes. Scale: `az aks scale -g $RG -n $CLUSTER --node-count 3` |
| PVC `Pending` for `managed-csi` with no pod | Normal: `WaitForFirstConsumer`. It binds once a pod uses it |
| Frontend `CrashLoopBackOff` | It pip-installs packages at start and needs outbound internet. `kubectl logs deploy/frontend` |
| `EXTERNAL-IP` stuck `<pending>` | Wait 2-3 min. Check `kubectl describe svc frontend` events and public IP quota |
| `pg_promote` returns `ERROR: recovery is not in progress` | That pod is already a primary. Run `./scripts/status.sh` |
| After failover, old primary comes back and **wipes** | Expected: the ConfigMap says it is now a replica. That is the repair path |
| Want to start completely fresh | `kubectl delete ns pg-demo`, then redo Part 2. New disks, `pg-a` primary again |

---

## What is simplified vs production

- Passwords are in a plain Secret → use **Azure Key Vault + Secrets Store CSI driver**
- The frontend connects as the `postgres` superuser → create a least-privilege app role
- Failover is manual → use an **operator** (CloudNativePG, Patroni, Crunchy) or **Azure Database for PostgreSQL Flexible Server**
- Async replication → consider **synchronous** replication for RPO = 0
- No backups → add WAL archiving / base backups to Azure Blob (e.g. CloudNativePG + Barman)
- The frontend pip-installs at startup → build a proper image and push to **Azure Container Registry**
- No zones → for real HA, spread nodes across **availability zones** (`--zones 1 2 3`) and use ZRS disks (`managed-csi` with `skuName: Premium_ZRS`)
