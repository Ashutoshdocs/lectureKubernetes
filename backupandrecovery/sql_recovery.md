# Kubernetes Practical: Rock Paper Scissors + Migrate Cluster 1 → Cluster 2

Two single-VM Kubernetes clusters. The goal:

1. **Run the app on cluster 1** — a 3-tier **Rock Paper Scissors** game (nginx
   frontend on a **NodePort**, Node.js API that referees rounds, **MySQL** for
   the scores).
2. **Bring it up on cluster 2 exactly where you left off** — same objects, same
   scores.
3. Along the way, practise **etcd snapshot, dump and (optionally) restore**.

## Read this first: what etcd holds vs. what it doesn't

This trips everyone up, so it's up top.

- **etcd stores Kubernetes objects only** — Deployments, Pods, Services,
  ConfigMaps, Secrets, namespaces. An etcd snapshot is a backup of *the cluster's
  object definitions*.
- **etcd does NOT store your MySQL rows.** The RPS scores live in MySQL's data
  files on the node volume (`/mnt/data/mysql`), which Kubernetes never puts in
  etcd. **No etcd snapshot will ever contain a player's score.**

So "move the app and keep the scores" is always **two** backups:

| What | Where it lives | How to back it up |
|---|---|---|
| App objects (Deployments, Services, Secret…) | etcd | your `manifests/` YAML **or** an etcd snapshot |
| Game data (players/scores) | MySQL volume | `mysqldump` (see `mysql-backup.sh`) |

Because you already have the objects as YAML, the clean migration is **re-apply
the manifests on cluster 2 + restore the MySQL dump**. That's Path A below and
it's the recommended route. The full etcd-clone (Path B) is included as an
advanced disaster-recovery exercise, but it still needs the MySQL dump.

```
   CLUSTER 1 (VM #1)                         CLUSTER 2 (VM #2)
 ┌──────────────────────────┐             ┌──────────────────────────┐
 │ frontend (NodePort 30080)│             │ frontend (NodePort 30080)│
 │   /api ─▶ backend        │  manifests  │   /api ─▶ backend        │
 │            │             │  ─apply──▶  │            │             │
 │            ▼             │             │            ▼             │
 │        MySQL (PVC) ──────┼── mysqldump─┼─▶ MySQL (PVC)            │
 │                          │  + restore  │                          │
 │        etcd (snapshot) ──┼── optional ─┼─▶ etcd (Path B clone)    │
 └──────────────────────────┘             └──────────────────────────┘
```

---

## 1. What's in here

```
k8s-practical/
├── README.md
├── app/
│   ├── backend/            Node.js + Express API (referees rounds, talks to MySQL)
│   │   ├── server.js
│   │   ├── package.json
│   │   └── Dockerfile
│   └── frontend/           nginx: serves the UI + proxies /api to backend
│       ├── html/           index.html, style.css, app.js  (the RPS UI)
│       ├── nginx.conf
│       └── Dockerfile
├── manifests/              all Kubernetes YAML, applied in numeric order
│   ├── 00-namespace.yaml
│   ├── 01-mysql-secret.yaml
│   ├── 02-mysql-storage.yaml    (hostPath PV + PVC)
│   ├── 03-mysql.yaml            (Deployment + Service)
│   ├── 04-backend.yaml          (Deployment + Service)
│   └── 05-frontend.yaml         (Deployment + NodePort Service)
└── scripts/
    ├── build-images.sh          build the two images
    ├── load-images.sh           load them into the cluster (no registry)
    ├── deploy.sh                apply manifests + wait
    ├── mysql-backup.sh          dump the scores      (cluster 1)  ← migration
    ├── mysql-restore.sh         load the scores      (cluster 2)  ← migration
    ├── etcd-backup.sh           snapshot save        (cluster 1)
    ├── etcd-restore-and-dump.sh restore + dump only  (cluster 2, safe)
    ├── etcd-dump-live.sh        dump a live cluster's own etcd
    └── etcd-clone-into.sh       Path B: restore snapshot into THIS cluster's etcd
```

## 2. Prerequisites

Two VMs, each a single-node cluster (**kubeadm** recommended — real etcd static
pod). On kubeadm, untaint the control plane so pods can schedule:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
```

**Both** VMs need `kubectl` and **Docker** (each cluster needs the images built
locally, since there's no shared registry). minikube/kind also work for the app;
kubeadm is best for the etcd parts.

---

## 3. Cluster 1 — deploy the app

From the `k8s-practical/` folder on cluster 1:

```bash
chmod +x scripts/*.sh
./scripts/build-images.sh      # build arcade-backend:v1 and arcade-frontend:v1
./scripts/load-images.sh       # load into the cluster (auto-detects the tool)
./scripts/deploy.sh            # apply manifests + wait; prints the URL
```

Open `http://<NODE_IP>:30080`, enter a handle, throw 🪨 / 📄 / ✂️ against the
machine. The server decides win/lose/draw and records it. The **top-scorers**
leaderboard (points = win×3 + draw) updates on every throw.

Confirm the scores are in MySQL:

```bash
kubectl -n arcade exec -it deploy/mysql -- \
  mysql -uarcade -parcadepass arcadedb -e \
  "SELECT name, wins, losses, draws, (wins*3+draws) AS points FROM players ORDER BY points DESC;"
```

Play a few rounds now so there's real data to migrate.

---

## 4. Path A — migrate to cluster 2 (recommended)

This recreates the app on cluster 2 and carries the scores over. Nothing here
touches etcd internals, so it can't break either cluster's control plane.

### 4.1 On cluster 1 — back up the scores

```bash
./scripts/mysql-backup.sh                 # writes arcade-db-<timestamp>.sql
scp arcade-db-*.sql azureuser@CLUSTER2_IP:~/
```

### 4.2 Copy the project to cluster 2

If it isn't there already:

```bash
scp -r k8s-practical azureuser@CLUSTER2_IP:~/
```

### 4.3 On cluster 2 — build, deploy, restore

```bash
cd ~/k8s-practical
chmod +x scripts/*.sh

./scripts/build-images.sh                 # cluster 2 needs the images too
./scripts/load-images.sh
./scripts/deploy.sh                       # brings up frontend/backend/mysql

# load the scores into the fresh MySQL
./scripts/mysql-restore.sh ~/arcade-db-<timestamp>.sql
```

### 4.4 Verify

```bash
kubectl -n arcade get pods
kubectl -n arcade exec deploy/mysql -- \
  mysql -uarcade -parcadepass arcadedb -e \
  "SELECT name, (wins*3+draws) AS points FROM players ORDER BY points DESC LIMIT 5;"
```

Open `http://<CLUSTER2_NODE_IP>:30080` — the leaderboard is exactly where you
left off. **Migration done.** Sections 5–7 are the etcd exercises.

---

## 5. Cluster 1 — snapshot etcd

Run on the control-plane VM (needs `sudo`). etcd runs as a static pod with certs
under `/etc/kubernetes/pki/etcd`.

```bash
./scripts/etcd-backup.sh                  # writes ~/etcd-backup/etcd-snapshot-<ts>.db
scp ~/etcd-backup/etcd-snapshot-*.db azureuser@CLUSTER2_IP:~/
```

It runs, in effect:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ~/etcd-backup/etcd-snapshot-<timestamp>.db
```

and prints `snapshot status` so you can confirm it's valid.

---

## 6. Cluster 2 — dump a snapshot (safe, read-only)

Inspect cluster 1's snapshot **without touching cluster 2's real etcd**. This is
inspection only — it does NOT make cluster 2 run cluster 1's workloads.

```bash
./scripts/etcd-restore-and-dump.sh ~/etcd-snapshot-<timestamp>.db
```

It restores the snapshot into a throwaway data dir, starts a temporary etcd on
ports 12379/12380, and writes to `etcd-output/`:

- `etcd-keys.txt` — every key, e.g. `/registry/deployments/arcade/backend`
- `etcd-full.json` — keys **and** values (values are base64 protobuf)
- `etcd-inventory.txt` — object count per resource type

Check your app is in the snapshot:

```bash
grep arcade etcd-output/etcd-keys.txt
awk -F/ '/^\/registry\/pods\//{print $4}' etcd-output/etcd-keys.txt | sort | uniq -c
```

> **Why `kubectl get po` on cluster 2 still shows nothing after this:** the dump
> only wrote files. Cluster 2's own etcd was never changed. To actually run the
> workloads on cluster 2, use Path A (section 4) or Path B (section 7).

To dump the cluster you're standing on instead:

```bash
./scripts/etcd-dump-live.sh
```

---

## 7. Path B — clone cluster 1's etcd into cluster 2 (advanced, destructive)

> ⚠️ **This replaces cluster 2's entire control-plane state with cluster 1's.**
> Cluster 2 *becomes* cluster 1. Only do this on a throwaway cluster 2. It is a
> disaster-recovery drill, not a normal migration — Path A is safer and simpler.
> **It still does not carry MySQL data**, so you run the `mysql-backup.sh` /
> `mysql-restore.sh` steps as well.

Because a cluster's identity lives in its CA and service-account keys, a proper
clone also copies cluster 1's PKI and regenerates the IP-bound certs for
cluster 2. `etcd-clone-into.sh` does the etcd part with a backup and guard rails;
the PKI steps are spelled out so you know what's happening.

### 7.1 Copy cluster 1's identity to cluster 2 (once)

On cluster 1:
```bash
sudo tar czf ~/pki.tgz -C /etc/kubernetes/pki ca.crt ca.key sa.pub sa.key \
  front-proxy-ca.crt front-proxy-ca.key etcd/ca.crt etcd/ca.key
scp ~/pki.tgz azureuser@CLUSTER2_IP:~/
```

On cluster 2 (regenerate the certs that are tied to cluster 2's own IP):
```bash
sudo tar xzf ~/pki.tgz -C /etc/kubernetes/pki
CLUSTER2_IP=$(hostname -I | awk '{print $1}')
sudo rm -f /etc/kubernetes/pki/apiserver.{crt,key} \
           /etc/kubernetes/pki/etcd/server.{crt,key} \
           /etc/kubernetes/pki/etcd/peer.{crt,key}
sudo kubeadm init phase certs apiserver --apiserver-advertise-address "$CLUSTER2_IP"
sudo kubeadm init phase certs etcd-server
sudo kubeadm init phase certs etcd-peer
```

### 7.2 Restore the snapshot into cluster 2's etcd

```bash
./scripts/etcd-clone-into.sh ~/etcd-snapshot-<timestamp>.db
```

The script backs up `/etc/kubernetes/manifests/etcd.yaml` and `/var/lib/etcd`
first, stops the static pods, restores the snapshot into a fresh `/var/lib/etcd`
with the correct `--name` / `--initial-cluster` for cluster 2, then restarts the
control plane.

### 7.3 Bring the app data over and verify

```bash
./scripts/mysql-restore.sh ~/arcade-db-<timestamp>.sql   # after MySQL is Ready
kubectl get ns
kubectl -n arcade get pods
```

> **If kubectl misbehaves after this:** cluster 2's kubeconfig/certs may need to
> match the restored state. Because you copied cluster 1's CA, cluster 1's
> admin.conf will also work — copy it over if needed. This fiddliness is exactly
> why Path A is recommended.

---

## 8. Recovery — "I edited etcd.yaml and my cluster went empty"

If you ever ran the old one-liner that repointed etcd at `/var/lib/etcd-restored`
and your cluster came up empty, your real data is still in `/var/lib/etcd`.
Point etcd back at it:

```bash
sudo grep -n 'var/lib/etcd' /etc/kubernetes/manifests/etcd.yaml   # confirm the path
sudo sed -i 's#/var/lib/etcd-restored#/var/lib/etcd#g' /etc/kubernetes/manifests/etcd.yaml
sudo rm -rf /var/lib/etcd-restored
# wait ~30-60s for kubelet to recreate the etcd pod:
sudo crictl ps | grep etcd
kubectl get ns          # your namespaces should be back
```

---

## 9. Cleanup

```bash
# app (either cluster)
kubectl delete namespace arcade
kubectl delete pv mysql-pv
sudo rm -rf /mnt/data/mysql            # wipe persisted MySQL data

# dump artifacts / backups
rm -rf etcd-output arcade-db-*.sql
```

---

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `ErrImagePull` / `ImagePullBackOff` | Image not loaded on that cluster. Re-run `load-images.sh`. Each cluster needs its own build/load. For kubeadm: `sudo ctr -n k8s.io images ls | grep arcade`. |
| Pods stuck `Pending` | On kubeadm, untaint the control plane (section 2). Also `kubectl -n arcade describe pod ...`. |
| MySQL pod `Pending`, PVC unbound | PV path/storageClass mismatch. `kubectl get pv,pvc -n arcade`; both use `storageClassName: manual`. |
| Leaderboard says "Could not reach the API" | Backend not ready. `kubectl -n arcade logs deploy/backend`. |
| `mysql-restore.sh` errors on connect | MySQL not Ready yet. `kubectl -n arcade rollout status deploy/mysql` first. |
| Scores didn't come across | You only moved the etcd snapshot. Scores live in MySQL — run `mysql-backup.sh` / `mysql-restore.sh` (section 4). |
| `kubectl get po` empty on cluster 2 after a dump | Expected — the dump writes files only. Use Path A or Path B to actually run the app. |
| `http://IP:30080` refused | Use the node InternalIP, not localhost; open the port in the cloud firewall/NSG. |
| etcd snapshot: cert errors | Run on the control-plane VM; check `ls /etc/kubernetes/pki/etcd/`. |
| etcd download fails | VM needs outbound `github.com`, or pre-install `etcd-client`. |

---

## 11. Credentials (lab only — change for anything real)

Defined in `manifests/01-mysql-secret.yaml`:

- root password: `rootpass123`
- database: `arcadedb`
- app user / password: `arcade` / `arcadepass`
