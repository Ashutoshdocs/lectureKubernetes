# etcd Backup & Same-Cluster Restore (Cluster 1 Disaster Recovery)

Back up cluster 1's etcd, then restore that snapshot **onto the same cluster** to
bring back Kubernetes objects that were deleted or lost. This is the classic
kubeadm etcd recovery drill: take a snapshot, break something, roll etcd back to
the snapshot.

This is a self-contained guide. It only needs cluster 1 — the control-plane VM.

## What an etcd restore does and does NOT recover

- ✅ **Recovers Kubernetes objects** that existed at snapshot time: namespaces,
  Deployments, Services, ConfigMaps, Secrets, PVC/PV objects, etc. If you
  `kubectl delete` something, restoring an earlier snapshot brings it back.
- ✅ **Your MySQL scores also survive** in this project — but *not because they're
  in etcd*. They live on a hostPath volume (`/mnt/data/mysql`) with
  `reclaimPolicy: Retain`, so the files stay on disk even if the PVC is deleted.
  When the restore brings the PVC/PV/Pod objects back, MySQL remounts the same
  files and the scores are there.
- ❌ **Does NOT undo changes made inside MySQL.** If the "lost data" was a
  `DELETE FROM players` or a dropped table, etcd can't help — that's a MySQL
  problem, restore it from a `mysqldump` instead (see `scripts/mysql-backup.sh`).
- ❌ **Does NOT recover the node's disk.** If `/mnt/data/mysql` itself was wiped,
  etcd won't bring the data back.

Rule of thumb: **etcd restore = rewind the cluster's object list to snapshot
time.** Anything stored outside etcd is out of scope.

---

## 0. Prerequisites

- A single-node **kubeadm** cluster (etcd runs as a static pod, certs under
  `/etc/kubernetes/pki/etcd`).
- Run everything on the control-plane VM as root (or with `sudo`).
- `kubectl` working before you start.

---

## 1. Take a snapshot (your safety point)

Using the helper from the main project:

```bash
cd ~/k8s-practical
sudo ./scripts/etcd-backup.sh
```

It writes `~/etcd-backup/etcd-snapshot-<timestamp>.db` and prints
`snapshot status` so you can confirm it's valid.

The raw command it runs, for reference:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ~/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db
```

Note the exact filename — you'll pass it to the restore step.

---

## 2. Simulate data loss

Confirm the app is there, then delete something:

```bash
kubectl -n arcade get all           # everything is running

# --- "oops" moment: delete a deployment (or the whole namespace) ---
kubectl -n arcade delete deploy backend
# or, bigger: kubectl delete namespace arcade

kubectl -n arcade get all           # backend is gone
```

---

## 3. Restore the snapshot onto this cluster

### Option A — scripted (recommended)

```bash
cd ~/k8s-practical
sudo ./scripts/etcd-restore-self.sh ~/etcd-backup/etcd-snapshot-<timestamp>.db
```

The script (type `YES` to confirm):

1. Reads this node's etcd identity (`--name`, `--initial-cluster`, peer URL)
   from `/etc/kubernetes/manifests/etcd.yaml`.
2. Backs up `etcd.yaml` and the current `/var/lib/etcd` into
   `~/etcd-restore-backup-<timestamp>/`.
3. Stops the control-plane static pods (moves the manifests aside).
4. Moves the current etcd data aside and restores the snapshot into a fresh
   `/var/lib/etcd`.
5. Puts the manifests back; kubelet restarts etcd + apiserver.
6. Waits for the API server, then tells you to verify.

### Option B — manual (learn the steps)

```bash
SNAP=~/etcd-backup/etcd-snapshot-<timestamp>.db

# 1. read this node's etcd identity BEFORE moving the manifest
NAME=$(grep -oP -- '--name=\K[^ ]+' /etc/kubernetes/manifests/etcd.yaml | head -1)
PEER=$(grep -oP -- '--initial-advertise-peer-urls=\K[^ ]+' /etc/kubernetes/manifests/etcd.yaml | head -1)
CLUSTER=$(grep -oP -- '--initial-cluster=\K[^ ]+' /etc/kubernetes/manifests/etcd.yaml | head -1)
echo "$NAME / $PEER / $CLUSTER"

# 2. stop the control plane (park the static pods)
sudo mkdir -p /etc/kubernetes/manifests-stopped
sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-stopped/
sleep 15

# 3. move the current etcd data aside (keep it, don't delete)
sudo mv /var/lib/etcd /var/lib/etcd.old-$(date +%s)

# 4. restore the snapshot into a fresh /var/lib/etcd
sudo ETCDCTL_API=3 etcdutl snapshot restore "$SNAP" \
  --name "$NAME" \
  --initial-cluster "$CLUSTER" \
  --initial-advertise-peer-urls "$PEER" \
  --data-dir /var/lib/etcd

# 5. restart the control plane
sudo mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
```

> **Why restore into `/var/lib/etcd` (not a new dir):** keeping the data-dir the
> same means you don't touch `etcd.yaml`'s volume path — the single most common
> way this goes wrong. If instead you restore into `/var/lib/etcd-restored`, you
> MUST also update the etcd-data **hostPath volume** in `etcd.yaml`, and a blind
> `sed` across the whole file can point etcd at an empty directory and start a
> brand-new empty cluster. Restoring in place avoids all of that.

> **`etcdutl` vs `etcdctl`:** newer etcd moved `snapshot restore` to `etcdutl`.
> If `etcdutl` isn't installed, download the etcd release tarball (it's inside),
> or the script fetches it for you.

---

## 4. Verify

```bash
kubectl get ns
kubectl -n arcade get all
kubectl -n arcade exec deploy/mysql -- \
  mysql -uarcade -parcadepass arcadedb -e \
  "SELECT name,(wins*3+draws) AS points FROM players ORDER BY points DESC LIMIT 5;"
```

The deleted objects are back, and (since the hostPath data survived) so are the
scores. Open `http://<NODE_IP>:30080` to confirm.

Give the app a minute — MySQL and the backend pods need to become Ready again.

---

## 5. Roll back the restore (if it went wrong)

Everything the script replaced is in `~/etcd-restore-backup-<timestamp>/`:

```bash
B=~/etcd-restore-backup-<timestamp>

# stop control plane
sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-stopped/ 2>/dev/null || true
sleep 15

# put the pre-restore data back
sudo rm -rf /var/lib/etcd
sudo mv "$B/etcd-data.old" /var/lib/etcd
sudo cp -a "$B/etcd.yaml.bak" /etc/kubernetes/manifests/etcd.yaml

# restart control plane
sudo mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
```

For the manual path, just move your `/var/lib/etcd.old-*` back into place the
same way.

---

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `kubectl` hangs / "connection refused" right after restore | Normal for 1–2 min while etcd + apiserver restart. `sudo crictl ps | grep -E 'etcd|apiserver'` to watch them come up. |
| Cluster comes back **empty** | etcd started on the wrong/empty data dir. Confirm the restore wrote files: `sudo ls /var/lib/etcd/member`. If empty, re-run the restore; if you edited `etcd.yaml`, check its `--data-dir` and the etcd-data hostPath both point at the restored dir. |
| `etcdutl: command not found` | Install `etcd-client`/download the etcd tarball, or use the scripted option which fetches it. |
| Objects back but MySQL pod `CrashLoopBackOff` | Give it time; check `kubectl -n arcade logs deploy/mysql`. Ensure `/mnt/data/mysql` still exists on the node. |
| Scores still missing after restore | They were changed *inside* MySQL, not deleted from Kubernetes — restore from a `mysqldump`, not etcd. Or `/mnt/data/mysql` was wiped. |
| Static pods don't restart | Check kubelet: `sudo systemctl status kubelet`; confirm the manifests are back in `/etc/kubernetes/manifests/`. |

---

## 7. One-line mental model

```
snapshot save   -> a frozen copy of every Kubernetes object
delete stuff    -> objects gone from the live cluster
snapshot restore-> etcd rewound to the frozen copy -> objects return
                   (data outside etcd — MySQL rows — is a separate backup)
```
