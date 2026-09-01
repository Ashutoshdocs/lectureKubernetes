# etcd Backup & Same-Cluster Restore — Cluster 1 Disaster Recovery

This guide demonstrates a complete **etcd disaster-recovery drill** for a
single-node kubeadm Kubernetes cluster.

The workflow is:

```text
Take etcd snapshot
       |
       v
Simulate Kubernetes object loss
       |
       v
Restore snapshot onto the SAME cluster
       |
       v
Kubernetes objects return
       |
       v
Verify the application and persistent data
```

This is the classic kubeadm etcd recovery exercise: take a known-good snapshot,
break something, and rewind etcd to the snapshot.

> **Important:** An etcd restore rewinds the Kubernetes control-plane object
> state. It does not restore arbitrary data stored outside etcd.

---

# 1. What an etcd Restore Does and Does NOT Recover

## ✅ What it recovers

An etcd snapshot contains Kubernetes API objects that existed at snapshot time,
including objects such as:

- Namespaces
- Deployments
- StatefulSets
- Services
- ConfigMaps
- Secrets
- PersistentVolumeClaims
- PersistentVolumes
- ServiceAccounts
- Roles / RoleBindings
- Other Kubernetes API state stored in etcd

For example, if:

```bash
kubectl -n arcade delete deploy backend
```

is executed after the snapshot was taken, restoring that snapshot can bring the
Deployment object back.

---

## ✅ Why MySQL scores survive in this project

The MySQL scores are **not stored in etcd**.

They live in MySQL's data directory:

```text
/mnt/data/mysql
```

The project uses a hostPath volume with:

```text
reclaimPolicy: Retain
```

Therefore, deleting Kubernetes objects does not automatically delete the
MySQL files from the host.

When etcd restores the Kubernetes objects:

```text
PVC/PV/Pod
    |
    v
MySQL mounts /mnt/data/mysql
    |
    v
Existing MySQL database files
    |
    v
Scores are available again
```

---

## ❌ What etcd does NOT recover

An etcd restore does **not** restore changes made inside MySQL.

For example:

```sql
DELETE FROM players;
```

or:

```sql
DROP TABLE players;
```

is a MySQL data change.

etcd cannot undo it.

For MySQL data recovery, use a MySQL backup such as:

```text
scripts/mysql-backup.sh
```

Likewise, if the host itself loses:

```text
/mnt/data/mysql
```

etcd cannot recreate those files.

---

## Rule of Thumb

```text
etcd restore
    =
rewind Kubernetes object state
to the time of the snapshot
```

Anything stored outside etcd requires its own backup strategy.

---

# 2. Prerequisites

This guide assumes:

- A single-node **kubeadm** Kubernetes cluster
- The control-plane VM is the only cluster node
- etcd runs as a static pod
- etcd certificates are under:

```text
/etc/kubernetes/pki/etcd
```

- `kubectl` works before starting the exercise
- The project repository exists at:

```text
~/k8s-practical
```

- You have root access or can use `sudo`

---

# 3. Understand the Recovery Architecture

A kubeadm control plane normally looks approximately like:

```text
                         Kubernetes
                              |
                         kube-apiserver
                              |
                              v
                            etcd
                              |
                    +---------+---------+
                    |                   |
                    v                   v
             Kubernetes objects    Cluster state
```

During recovery:

```text
              etcd snapshot
                    |
                    v
          etcdutl snapshot restore
                    |
                    v
          /var/lib/etcd/member
                    |
                    v
             etcd static pod
                    |
                    v
             kube-apiserver
                    |
                    v
          Kubernetes objects
                    |
                    v
             Application
```

The key point is:

> **The snapshot restores the etcd database, not the entire VM filesystem.**

---

# 4. Install etcd 3.5.16 Tools

The restore procedure uses `etcdutl`.

Download the official etcd 3.5.16 Linux AMD64 archive:

```bash
cd /tmp

sudo rm -rf etcd-v3.5.16-linux-amd64
sudo rm -f etcd-v3.5.16-linux-amd64.tar.gz

wget https://github.com/etcd-io/etcd/releases/download/v3.5.16/etcd-v3.5.16-linux-amd64.tar.gz
```

Extract it:

```bash
tar -xzf etcd-v3.5.16-linux-amd64.tar.gz
```

Inspect the archive:

```bash
ls -l /tmp/etcd-v3.5.16-linux-amd64/
```

You should see files similar to:

```text
etcd
etcdctl
etcdutl
README.md
```

---

# 5. Install etcd, etcdctl and etcdutl

Install `etcdutl`:

```bash
sudo install -m 0755 \
  /tmp/etcd-v3.5.16-linux-amd64/etcdutl \
  /usr/local/bin/etcdutl
```

Install `etcdctl`:

```bash
sudo install -m 0755 \
  /tmp/etcd-v3.5.16-linux-amd64/etcdctl \
  /usr/local/bin/etcdctl
```

Install the etcd server binary:

```bash
sudo install -m 0755 \
  /tmp/etcd-v3.5.16-linux-amd64/etcd \
  /usr/local/bin/etcd
```

Verify:

```bash
which etcdutl
which etcdctl
which etcd
```

Expected:

```text
/usr/local/bin/etcdutl
/usr/local/bin/etcdctl
/usr/local/bin/etcd
```

Check versions:

```bash
etcdutl version
etcdctl version
etcd --version
```

The installed version should correspond to:

```text
3.5.16
```

---

# 6. Take an etcd Snapshot — Your Safety Point

Move into the project:

```bash
cd ~/k8s-practical
```

Use the project's backup helper:

```bash
sudo ./scripts/etcd-backup.sh
```

The helper should create a snapshot similar to:

```text
~/etcd-backup/etcd-snapshot-<timestamp>.db
```

The script also checks the snapshot status.

---

# 7. Raw etcd Snapshot Command

For learning, the underlying command is:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ~/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db
```

The important pieces are:

```text
endpoint
    |
    v
https://127.0.0.1:2379

CA certificate
    |
    v
/etc/kubernetes/pki/etcd/ca.crt

client/server certificate
    |
    v
/etc/kubernetes/pki/etcd/server.crt

private key
    |
    v
/etc/kubernetes/pki/etcd/server.key
```

---

# 8. Record the Snapshot Filename

List the backup directory:

```bash
ls -lh ~/etcd-backup/
```

Example:

```text
etcd-snapshot-20260901-210000.db
```

You will need the exact filename during restoration.

Set it:

```bash
SNAP=~/etcd-backup/etcd-snapshot-<timestamp>.db
```

Verify:

```bash
echo "$SNAP"
ls -lh "$SNAP"
```

---

# 9. Verify the Snapshot

Check the snapshot with `etcdutl`:

```bash
sudo etcdutl snapshot status "$SNAP" -w table
```

Example:

```text
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| abc12345 |    12345 |        150 | 2.1 MB     |
+----------+----------+------------+------------+
```

The actual hash, revision, key count and size will be different.

Do **not** continue if:

- The snapshot file does not exist
- The path is incorrect
- `snapshot status` reports an error
- The snapshot is not the backup you intend to restore

---

# 10. Verify the Cluster Before Breaking Anything

Make sure the cluster is healthy:

```bash
kubectl get nodes
```

Then:

```bash
kubectl get pods -A
```

Check the application:

```bash
kubectl -n arcade get all
```

You should see the application resources before simulating the disaster.

---

# 11. Simulate Data Loss

The goal is to delete Kubernetes objects **after the snapshot has been taken**.

Check the application:

```bash
kubectl -n arcade get all
```

Delete the backend Deployment:

```bash
kubectl -n arcade delete deploy backend
```

Verify:

```bash
kubectl -n arcade get all
```

The backend Deployment should now be gone.

---

## Bigger Disaster Simulation

You can simulate a larger Kubernetes object loss:

```bash
kubectl delete namespace arcade
```

> **Warning:** This is much more destructive. Only do this in the dedicated
> recovery lab/project cluster.

---

# 12. Verify the Object Is Gone

For the Deployment test:

```bash
kubectl -n arcade get deploy
```

The `backend` Deployment should no longer exist.

For the namespace test:

```bash
kubectl get ns
```

The `arcade` namespace should no longer exist.

Now the cluster represents the simulated disaster.

---

# 13. Restore the Snapshot — Recommended Scripted Method

The project includes a helper:

```bash
cd ~/k8s-practical
sudo ./scripts/etcd-restore-self.sh \
  ~/etcd-backup/etcd-snapshot-<timestamp>.db
```

The script asks for confirmation.

Type:

```text
YES
```

only when you are certain you want to restore.

---

# 14. What the Restore Script Does

The scripted restore performs the following sequence:

```text
1. Read etcd identity
        |
        v
2. Back up etcd.yaml
        |
        v
3. Back up current /var/lib/etcd
        |
        v
4. Stop static-pod control plane
        |
        v
5. Move current etcd data aside
        |
        v
6. Restore snapshot into /var/lib/etcd
        |
        v
7. Put manifests back
        |
        v
8. Kubelet restarts etcd
        |
        v
9. kube-apiserver reconnects
        |
        v
10. Verify cluster
```

The script reads the node's etcd identity from:

```text
/etc/kubernetes/manifests/etcd.yaml
```

Important values include:

```text
--name=
--initial-cluster=
--initial-advertise-peer-urls=
```

---

# 15. Manual Restore — Learn the Actual Steps

The scripted method is recommended for repeatable recovery.

The manual method is useful for understanding what is actually happening.

## Step 1 — Define the snapshot

```bash
SNAP=~/etcd-backup/etcd-snapshot-<timestamp>.db
```

---

## Step 2 — Read the etcd identity BEFORE moving the manifest

```bash
NAME=$(grep -oP -- '--name=\K[^ ]+' \
  /etc/kubernetes/manifests/etcd.yaml | head -1)

PEER=$(grep -oP -- '--initial-advertise-peer-urls=\K[^ ]+' \
  /etc/kubernetes/manifests/etcd.yaml | head -1)

CLUSTER=$(grep -oP -- '--initial-cluster=\K[^ ]+' \
  /etc/kubernetes/manifests/etcd.yaml | head -1)
```

Display them:

```bash
echo "NAME=$NAME"
echo "PEER=$PEER"
echo "CLUSTER=$CLUSTER"
```

For a single-node cluster, the values may conceptually look like:

```text
NAME=vm-k8s-master
PEER=https://<MASTER-IP>:2380
CLUSTER=vm-k8s-master=https://<MASTER-IP>:2380
```

**Do not blindly use these examples.**

Use your actual manifest values.

---

# 16. Inspect the etcd Manifest Directly

You can also inspect the relevant parameters:

```bash
sudo grep -E \
  -- '--name=|--initial-cluster=|--initial-advertise-peer-urls=' \
  /etc/kubernetes/manifests/etcd.yaml
```

Also inspect the data directory:

```bash
sudo grep -E \
  -- '--data-dir=|hostPath:|mountPath:' \
  /etc/kubernetes/manifests/etcd.yaml
```

This is important because the restored data directory must match the directory
used by the running etcd container.

---

# 17. Stop the Static-Pod Control Plane

Create the holding directory:

```bash
sudo mkdir -p /etc/kubernetes/manifests-stopped
```

Move the static pod manifests out:

```bash
sudo mv /etc/kubernetes/manifests/*.yaml \
  /etc/kubernetes/manifests-stopped/
```

Wait for kubelet to stop the control-plane pods:

```bash
sleep 15
```

Verify:

```bash
ls -lah /etc/kubernetes/manifests/
```

The active manifest directory should be empty.

> `kubectl` may stop working while the API server is down. This is expected.

---

# 18. Preserve the Existing etcd Data

Do **not** immediately delete `/var/lib/etcd`.

Move it aside:

```bash
sudo mv /var/lib/etcd \
  /var/lib/etcd.old-$(date +%s)
```

Verify:

```bash
sudo ls -ld /var/lib/etcd.old-*
```

Keeping the old data is an important recovery safety measure.

---

# 19. Restore the Snapshot Into `/var/lib/etcd`

Run:

```bash
sudo ETCDCTL_API=3 etcdutl snapshot restore "$SNAP" \
  --name "$NAME" \
  --initial-cluster "$CLUSTER" \
  --initial-advertise-peer-urls "$PEER" \
  --data-dir /var/lib/etcd
```

The important part is:

```text
--data-dir /var/lib/etcd
```

The restored database is created as a new etcd data directory.

---

# 20. Why Restore to `/var/lib/etcd`?

The existing kubeadm etcd manifest normally mounts a host directory into the
etcd container.

For example, conceptually:

```text
Host:
    /var/lib/etcd
          |
          | hostPath
          v
Container:
    /var/lib/etcd
```

Therefore, restoring directly to:

```text
/var/lib/etcd
```

means you do not need to modify the etcd manifest's volume configuration.

---

## Dangerous Alternative

If you restore into:

```text
/var/lib/etcd-restored
```

you must also update the etcd static pod's hostPath configuration.

A careless edit can cause etcd to start against an empty directory.

That can result in an apparently new/empty etcd cluster.

Therefore:

> **For this single-node recovery drill, restoring to `/var/lib/etcd` is the
> simplest and safest approach.**

---

# 21. `etcdutl` vs `etcdctl`

For modern etcd versions, snapshot restore is performed using:

```bash
etcdutl snapshot restore
```

not:

```bash
etcdctl snapshot restore
```

That is why this guide installs:

```text
etcdutl
```

from the etcd 3.5.16 release archive.

If you see:

```text
etcdutl: command not found
```

verify:

```bash
which etcdutl
```

If necessary, install it from the downloaded etcd archive as shown earlier.

---

# 22. Verify the Restored Data Directory

After the restore succeeds:

```bash
sudo ls -lah /var/lib/etcd
```

You should see:

```text
member/
```

Inspect the contents:

```bash
sudo find /var/lib/etcd -maxdepth 3 -type f | head -30
```

A typical structure contains:

```text
/var/lib/etcd/
└── member/
    ├── snap/
    └── wal/
```

The exact files can vary.

---

# 23. Check Ownership

Check:

```bash
sudo ls -ld /var/lib/etcd
```

Compare it with the old directory:

```bash
sudo ls -ld /var/lib/etcd.old-*
```

Do not blindly change ownership.

If the original installation used:

```text
root:root
```

then:

```bash
sudo chown -R root:root /var/lib/etcd
```

Otherwise, preserve the ownership expected by your installation.

---

# 24. Restore the Static Pod Manifests

Only after the restore succeeds:

```bash
sudo mv /etc/kubernetes/manifests-stopped/*.yaml \
  /etc/kubernetes/manifests/
```

Verify:

```bash
ls -lah /etc/kubernetes/manifests/
```

Kubelet should detect the manifests and restart the control plane.

---

# 25. Watch the Control Plane Recover

Watch the kube-system pods:

```bash
watch -n 2 'kubectl get pods -n kube-system'
```

Or:

```bash
kubectl get pods -n kube-system
```

You should eventually see components such as:

```text
etcd-vm-k8s-master
kube-apiserver-vm-k8s-master
kube-controller-manager-vm-k8s-master
kube-scheduler-vm-k8s-master
```

with:

```text
Running
```

It may take a short time for the API server to become available again.

---

# 26. Verify Kubernetes Objects Returned

Check namespaces:

```bash
kubectl get ns
```

The namespace from the snapshot should be present again.

For the arcade application:

```bash
kubectl -n arcade get all
```

If the `backend` Deployment was deleted after the snapshot, it should now be
present again.

---

# 27. Verify the MySQL Data

Because the project stores MySQL data outside etcd on:

```text
/mnt/data/mysql
```

the MySQL files should still exist.

Check the host:

```bash
sudo ls -lah /mnt/data/mysql
```

Then check the MySQL pod:

```bash
kubectl -n arcade get pods
```

Once MySQL is Ready, run:

```bash
kubectl -n arcade exec deploy/mysql -- \
  mysql -uarcade -parcadepass arcadedb -e \
  "SELECT name,(wins*3+draws) AS points FROM players ORDER BY points DESC LIMIT 5;"
```

The scores should still be present because the hostPath data was not part of the
etcd restore.

---

# 28. Verify the Application

Check everything:

```bash
kubectl -n arcade get all
```

Then open:

```text
http://<NODE_IP>:30080
```

Replace:

```text
<NODE_IP>
```

with the actual control-plane/node IP.

Give the application a little time if MySQL or the backend is still starting.

---

# 29. Important: etcd Restore vs MySQL Restore

This distinction is critical.

## Kubernetes object deleted

Example:

```bash
kubectl delete deploy backend -n arcade
```

Recovery:

```text
etcd snapshot restore
```

---

## MySQL row deleted

Example:

```sql
DELETE FROM players WHERE name='Alice';
```

Recovery:

```text
mysqldump / MySQL backup
```

---

## HostPath directory deleted

Example:

```bash
sudo rm -rf /mnt/data/mysql
```

Recovery:

```text
filesystem backup / MySQL backup
```

---

## Mental model

```text
                    DATA
                     |
          +----------+----------+
          |                     |
          v                     v
   Kubernetes objects      MySQL database
          |                     |
          v                     v
         etcd              /mnt/data/mysql
          |                     |
          v                     v
   etcd snapshot          MySQL backup
```

---

# 30. Roll Back the Restore If Something Goes Wrong

The scripted recovery should preserve the pre-restore state under a directory
similar to:

```text
~/etcd-restore-backup-<timestamp>/
```

Set:

```bash
B=~/etcd-restore-backup-<timestamp>
```

Inspect it:

```bash
ls -lah "$B"
```

You may find:

```text
etcd.yaml.bak
etcd-data.old
```

---

## Stop the Control Plane

```bash
sudo mkdir -p /etc/kubernetes/manifests-stopped

sudo mv /etc/kubernetes/manifests/*.yaml \
  /etc/kubernetes/manifests-stopped/ 2>/dev/null || true

sleep 15
```

---

## Restore the Pre-Restore etcd Data

```bash
sudo rm -rf /var/lib/etcd
sudo mv "$B/etcd-data.old" /var/lib/etcd
```

Restore the etcd manifest if required:

```bash
sudo cp -a "$B/etcd.yaml.bak" \
  /etc/kubernetes/manifests/etcd.yaml
```

Then restore the remaining manifests:

```bash
sudo mv /etc/kubernetes/manifests-stopped/*.yaml \
  /etc/kubernetes/manifests/
```

> The exact rollback files depend on how the recovery script created its
> backup directory. Inspect the directory before moving or deleting anything.

---

# 31. Manual Rollback

If you used the manual recovery procedure and have:

```text
/var/lib/etcd.old-<timestamp>
```

stop the control plane again:

```bash
sudo mkdir -p /etc/kubernetes/manifests-stopped

sudo mv /etc/kubernetes/manifests/*.yaml \
  /etc/kubernetes/manifests-stopped/

sleep 15
```

Remove the restored directory:

```bash
sudo rm -rf /var/lib/etcd
```

Move the old directory back:

```bash
sudo mv /var/lib/etcd.old-<timestamp> /var/lib/etcd
```

Restore the manifests:

```bash
sudo mv /etc/kubernetes/manifests-stopped/*.yaml \
  /etc/kubernetes/manifests/
```

Then wait for the control plane to recover.

---

# 32. Troubleshooting

## `kubectl` hangs or connection is refused

Immediately after the restore, this can be normal.

Check the containers:

```bash
sudo crictl ps | grep -E 'etcd|apiserver'
```

Also check kubelet:

```bash
sudo systemctl status kubelet
```

Give the control plane some time to restart.

---

## Cluster comes back empty

This usually indicates etcd started against the wrong or empty data directory.

Check:

```bash
sudo ls -lah /var/lib/etcd/member
```

Then inspect the etcd manifest:

```bash
sudo grep -E \
  -- '--data-dir=|hostPath:|mountPath:' \
  /etc/kubernetes/manifests/etcd.yaml
```

Make sure the restored directory and the etcd volume configuration match.

---

## `etcdutl: command not found`

Check:

```bash
which etcdutl
```

If missing, install it from the etcd 3.5.16 archive:

```bash
sudo install -m 0755 \
  /tmp/etcd-v3.5.16-linux-amd64/etcdutl \
  /usr/local/bin/etcdutl
```

---

## Objects return but MySQL is CrashLoopBackOff

Check:

```bash
kubectl -n arcade get pods
```

Then:

```bash
kubectl -n arcade logs deploy/mysql
```

Also check the hostPath:

```bash
sudo ls -lah /mnt/data/mysql
```

Remember that etcd does not contain the MySQL database files.

---

## Objects return but scores are missing

If the MySQL pod and PVC/PV returned but scores are missing, determine whether:

1. The MySQL rows were changed/deleted after the snapshot.
2. `/mnt/data/mysql` was changed or wiped.
3. The MySQL pod is mounting a different directory.

Check:

```bash
sudo ls -lah /mnt/data/mysql
```

If the database contents themselves were lost, restore from a MySQL backup.

---

## Static pods do not restart

Check:

```bash
sudo systemctl status kubelet
```

Confirm the manifests exist:

```bash
ls -lah /etc/kubernetes/manifests/
```

You should have files such as:

```text
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

---

# 33. Recovery Verification Checklist

Use this checklist from start to finish:

```text
[ ] kubeadm cluster is healthy before the drill
[ ] kubectl works
[ ] etcd 3.5.16 downloaded
[ ] etcdutl installed
[ ] etcdctl installed
[ ] etcd installed
[ ] versions verified
[ ] etcd snapshot created
[ ] snapshot filename recorded
[ ] snapshot exists
[ ] snapshot status verified
[ ] application verified before disaster
[ ] Kubernetes object deleted
[ ] etcd identity recorded
[ ] NAME verified
[ ] CLUSTER verified
[ ] PEER verified
[ ] control-plane manifests stopped
[ ] old /var/lib/etcd preserved
[ ] snapshot restored
[ ] /var/lib/etcd/member exists
[ ] restored files verified
[ ] ownership verified
[ ] static pod manifests restored
[ ] etcd becomes Running
[ ] kube-apiserver becomes Running
[ ] controller-manager becomes Running
[ ] scheduler becomes Running
[ ] Kubernetes API responds
[ ] deleted Kubernetes object returns
[ ] arcade namespace returns
[ ] MySQL pod becomes Ready
[ ] MySQL data verified
[ ] application verified
```

---

# 34. Complete Recovery Flow

```text
                         CLUSTER 1
                            |
                            v
                  Healthy kubeadm cluster
                            |
                            v
                    etcd snapshot save
                            |
                            v
                 etcd-snapshot-<time>.db
                            |
                            v
                  Verify snapshot status
                            |
                            v
                   Simulate object loss
                            |
                            v
                  kubectl delete object
                            |
                            v
                  Object disappears
                            |
                            v
                  STOP STATIC PODS
                            |
                            v
              Preserve /var/lib/etcd
                            |
                            v
              etcdutl snapshot restore
                            |
                            v
               /var/lib/etcd/member
                            |
                            v
                 RESTORE MANIFESTS
                            |
                            v
                       kubelet
                            |
                            v
                          etcd
                            |
                            v
                    kube-apiserver
                            |
                            v
                 Kubernetes API state
                            |
                            v
                 Deleted object returns
                            |
                            v
                  Application recovers
```

---

# 35. What Happens to MySQL?

The complete data path in this project is:

```text
                   Kubernetes
                       |
                       v
                      etcd
                       |
          +------------+------------+
          |                         |
          v                         v
     Namespace                  PVC/PV
                                     |
                                     v
                                  MySQL Pod
                                     |
                                     v
                         /mnt/data/mysql
                                     |
                                     v
                              MySQL database
                                     |
                                     v
                                  Scores
```

An etcd restore restores the Kubernetes side:

```text
Namespace
Deployment
Service
PVC
PV
Pod
```

The hostPath remains:

```text
/mnt/data/mysql
```

Therefore:

```text
etcd restore
     |
     v
PVC/PV/Pod objects return
     |
     v
MySQL mounts existing hostPath
     |
     v
Existing database files
     |
     v
Scores return
```

But if:

```text
/mnt/data/mysql
```

was destroyed, etcd cannot recover it.

---

# 36. One-Line Mental Model

```text
snapshot save
      ->
frozen copy of Kubernetes object state
      ->
delete Kubernetes objects
      ->
objects disappear from live etcd
      ->
snapshot restore
      ->
etcd rewinds to snapshot time
      ->
Kubernetes objects return
      ->
external data such as MySQL rows requires its own backup
```

---

# 37. Golden Rule

Remember this:

```text
                 WHAT WAS LOST?
                       |
          +------------+------------+
          |                         |
          v                         v
 Kubernetes object             Application data
          |                         |
          v                         v
        etcd                     MySQL
          |                         |
          v                         v
 etcd snapshot restore          MySQL backup
```

**etcd backup protects Kubernetes control-plane state.**

**MySQL backup protects MySQL database state.**

**Filesystem backup protects data such as `/mnt/data/mysql`.**

A production disaster-recovery strategy should protect all three where
applicable.
