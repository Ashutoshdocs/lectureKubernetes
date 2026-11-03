# Kubernetes Volume Access Modes — Hands-on Demo (RWO · ROX · RWX · RWOP)

A complete lab on a **3-node kubeadm cluster** (1 control plane + 2 workers) with an
**NFS server**, that lets you *see* what each PersistentVolume access mode really
does — including the places where people usually get surprised.

| Mode | Short | Real meaning | Typical backend |
|---|---|---|---|
| `ReadWriteOnce` | **RWO** | RW by a **single node** at a time (many pods *on that node* OK) | Block: EBS, GCE PD, Azure Disk, local-path |
| `ReadOnlyMany` | **ROX** | Read-only, mounted by **many nodes** at once | NFS, CephFS, pre-populated volumes |
| `ReadWriteMany` | **RWX** | RW by **many nodes** simultaneously | Shared FS: NFS, CephFS, Azure Files, EFS |
| `ReadWriteOncePod` | **RWOP** | RW by **exactly one pod** cluster-wide (k8s 1.22+, GA 1.29) | Any CSI driver |

---

## Table of contents

1. [Lab architecture](#1-lab-architecture)
2. [Repository layout](#2-repository-layout)
3. [Step 0 – Build the cluster (optional)](#3-step-0--build-the-cluster-optional)
4. [Step 1 – Set up NFS (one script)](#4-step-1--set-up-nfs-one-script)
5. [Concepts you need before the demos](#5-concepts-you-need-before-the-demos)
6. [Demo 1 – ReadWriteOnce (RWO)](#6-demo-1--readwriteonce-rwo)
7. [Demo 2 – ReadOnlyMany (ROX)](#7-demo-2--readonlymany-rox)
8. [Demo 3 – ReadWriteMany (RWX)](#8-demo-3--readwritemany-rwx)
9. [Demo 4 – ReadWriteOncePod (RWOP)](#9-demo-4--readwriteoncepod-rwop)
10. [Side-by-side results](#10-side-by-side-results)
11. [Which mode should I use?](#11-which-mode-should-i-use)
12. [Troubleshooting](#12-troubleshooting)
13. [Cleanup](#13-cleanup)

---

## 1. Lab architecture

```
                    ┌──────────────────────────────────────────┐
                    │  k8s-cp   (control plane)  192.168.56.10 │
                    │  ─ kube-apiserver / scheduler / etcd     │
                    │  ─ NFS SERVER                            │
                    │      /srv/nfs/kubedata        (dynamic)  │
                    │      /srv/nfs/static/website  (ROX data) │
                    └───────────────┬──────────────────────────┘
                                    │  NFS v4.1 (tcp/2049)
                ┌───────────────────┴───────────────────┐
   ┌────────────▼─────────────┐            ┌────────────▼─────────────┐
   │ k8s-w1  192.168.56.11    │            │ k8s-w2  192.168.56.12    │
   │ kubelet, nfs-common      │            │ kubelet, nfs-common      │
   │ csi-nfs-node             │            │ csi-nfs-node             │
   │ local-path: /opt/local-… │            │ local-path: /opt/local-… │
   └──────────────────────────┘            └──────────────────────────┘
```

* The control plane keeps its default `NoSchedule` taint, so **all demo pods run on
  the two workers** — which is exactly what we need to prove "one node" vs "many nodes".
* Two StorageClasses are created:
  * **`nfs-csi`** — `csi-driver-nfs`, network storage, any node can mount it.
  * **`local-path`** — Rancher local-path, a directory on **one** worker's disk.
    It stands in for EBS / GCE PD / Azure Disk so we can show *real* RWO behaviour.

> IPs/hostnames above are examples. Use your own — nothing is hard-coded except
> through `demo.env`.

---

## 2. Repository layout

```
k8s-access-modes-demo/
├── README.md
├── scripts/
│   ├── cluster-setup.sh     # optional: kubeadm 1 CP + 2 workers
│   ├── setup-nfs.sh         # THE NFS script: server / client / k8s / all
│   └── cleanup.sh
└── manifests/
    ├── 00-namespace.yaml
    ├── 01-rwo/   a-rwo-local.yaml  b-rwo-other-node.yaml  c-rwo-nfs-gotcha.yaml
    ├── 02-rox/   a-rox-pv-pvc.yaml b-rox-readers.yaml     c-rox-careless-writer.yaml
    ├── 03-rwx/   rwx-shared.yaml
    └── 04-rwop/  a-rwop-pvc-writer1.yaml  b-rwop-writer2-same-node.yaml  c-rwop-preempt.yaml
```

Copy the folder to the control-plane node and `chmod +x scripts/*.sh`.

---

## 3. Step 0 – Build the cluster (optional)

Skip if you already have a 1 CP + 2 worker cluster (Ubuntu nodes, any CNI).

```bash
# on ALL three nodes
sudo ./scripts/cluster-setup.sh common

# on the control plane
sudo ./scripts/cluster-setup.sh controlplane     # prints "kubeadm join ..."

# on k8s-w1 and k8s-w2
sudo kubeadm join 192.168.56.10:6443 --token ... --discovery-token-ca-cert-hash sha256:...

# back on the control plane
kubectl get nodes -o wide
```

Expected:

```
NAME     STATUS   ROLES           AGE   VERSION
k8s-cp   Ready    control-plane   5m    v1.36.x
k8s-w1   Ready    <none>          2m    v1.36.x
k8s-w2   Ready    <none>          2m    v1.36.x
```

`K8S_MINOR=v1.37 sudo ./scripts/cluster-setup.sh common` picks a different release.

---

## 4. Step 1 – Set up NFS (one script)

`scripts/setup-nfs.sh` has four modes:

| Mode | Where | What it does |
|---|---|---|
| `server` | control plane (sudo) | installs `nfs-kernel-server`, creates `/srv/nfs/kubedata` + `/srv/nfs/static/website` (pre-filled with `index.html`), writes `/etc/exports.d/k8s-demo.exports`, opens ufw if active |
| `client [IP]` | each worker (sudo) | installs `nfs-common`, test-mounts the share and writes a probe file |
| `k8s <IP>` | anywhere `kubectl` works | installs **csi-driver-nfs v4.13.2**, creates StorageClass **`nfs-csi`**, installs **local-path-provisioner v0.0.37**, writes `demo.env` |
| `all` | control plane (sudo) | all of the above; reaches workers over `ssh` |

### Option A — everything from the control plane (needs ssh to workers)

```bash
sudo WORKERS="ubuntu@192.168.56.11 ubuntu@192.168.56.12" ./scripts/setup-nfs.sh all
```

### Option B — step by step

```bash
# control plane
sudo ./scripts/setup-nfs.sh server

# each worker
sudo ./scripts/setup-nfs.sh client 192.168.56.10

# control plane (as your normal user with kubeconfig)
./scripts/setup-nfs.sh k8s 192.168.56.10
```

If subnet auto-detection picks the wrong network (common with Vagrant/VirtualBox NAT):

```bash
sudo ALLOWED_CIDR=192.168.56.0/24 ./scripts/setup-nfs.sh server
sudo NFS_SERVER=192.168.56.10 ALLOWED_CIDR=192.168.56.0/24 WORKERS="..." ./scripts/setup-nfs.sh all
```

### Verify

```bash
showmount -e 192.168.56.10
kubectl get sc
kubectl -n kube-system get pods -l 'app in (csi-nfs-controller,csi-nfs-node)' -o wide
```

```
NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
local-path   rancher.io/local-path   Delete          WaitForFirstConsumer   false
nfs-csi      nfs.csi.k8s.io          Delete          Immediate              true
```

### Prepare the demo shell (do this in every new terminal)

```bash
cd k8s-access-modes-demo
source demo.env              # sets NFS_SERVER
kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=am-demo
```

> **Security note:** the exports use `no_root_squash` (csi-driver-nfs needs it to
> create/delete per-PV directories) and `/srv/nfs/kubedata` is `0777`. That is fine
> for a lab, not for production.

---

## 5. Concepts you need before the demos

Read these five points once — every demo proves one or more of them.

1. **Access modes are about NODES, not pods** — except RWOP.
   RWO means "one *node* may mount it read-write". Ten pods on that node can all write.

2. **An access mode on a PVC is a *request*; on a PV it is a *capability*.**
   The binder matches them. Whether anything *enforces* the rule at runtime depends on
   the storage:
   * block/attachable volumes → enforced by attach (Multi-Attach error) or node affinity
   * NFS / shared FS → **RWO is not enforced across nodes** (Demo 1c)
   * RWOP → enforced by kube-scheduler and kubelet for every CSI driver

3. **ROX does not mount anything read-only by itself.** The mount is read-only only if
   the pod says `persistentVolumeClaim.readOnly: true`, or the PV source says
   `readOnly: true` / `mountOptions: [ro]` (Demo 2c).

4. **A PV may advertise several modes** (e.g. `[ReadWriteOnce, ReadOnlyMany, ReadWriteMany]`),
   but a given mount uses one. `ReadWriteOncePod` must be the **only** mode listed.

5. **RWOP is CSI-only.** In-tree volume types (`nfs:`, `hostPath:`) cannot use it. Our
   `nfs-csi` StorageClass is CSI, so it works. Older CSI drivers that predate the
   feature still work because Kubernetes falls back to the classic single-node mode
   when talking to the driver; the "one pod" rule itself is enforced by Kubernetes.

Useful one-liner for every demo — shows which node each pod landed on:

```bash
kubectl get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
```

---

## 6. Demo 1 – ReadWriteOnce (RWO)

**Goal:** prove that RWO = one node, many pods on that node are fine; and see why
RWO on NFS is a trap.

### 1a. Three writers, one node-local volume

```bash
kubectl apply -f manifests/01-rwo/a-rwo-local.yaml
kubectl get pvc rwo-local-pvc            # Pending until the first pod schedules (WaitForFirstConsumer)
kubectl rollout status deploy/rwo-writer
kubectl get pods -l app=rwo-writer -o wide
```

Expected — **all three on the same worker**:

```
NAME                          READY   STATUS    NODE
rwo-writer-7d9c...-abcde      1/1     Running   k8s-w1
rwo-writer-7d9c...-fghij      1/1     Running   k8s-w1
rwo-writer-7d9c...-klmno      1/1     Running   k8s-w1
```

Why? Look at the PV that local-path created:

```bash
PV=$(kubectl get pvc rwo-local-pvc -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV -o jsonpath='{.spec.nodeAffinity}' ; echo
# {"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["k8s-w1"]}]}]}}
```

All three pods write to the same file — many pods, one node, one RWO volume:

```bash
POD=$(kubectl get pod -l app=rwo-writer -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- tail -6 /data/log.txt
```

```
10:15:01 pod=rwo-writer-...-abcde node=k8s-w1
10:15:02 pod=rwo-writer-...-fghij node=k8s-w1
10:15:02 pod=rwo-writer-...-klmno node=k8s-w1
```

### 1b. Try to use it from the other worker

```bash
kubectl apply -f manifests/01-rwo/b-rwo-other-node.yaml
kubectl get pod rwo-intruder                   # Pending forever
kubectl describe pod rwo-intruder | sed -n '/Events/,$p'
```

```
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node(s) didn't match pod anti-affinity rules,
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  1 node(s) had volume node affinity conflict. ...
```

✅ **Learned:** for real single-node storage, a second *node* cannot use an RWO volume.
On a cloud disk (EBS/PD/Azure Disk) the same situation shows up as
`Multi-Attach error for volume ... Volume is already used by pod(s) ...`.

```bash
kubectl delete pod rwo-intruder
```

### 1c. The gotcha — RWO on NFS

```bash
kubectl apply -f manifests/01-rwo/c-rwo-nfs-gotcha.yaml
kubectl rollout status deploy/rwo-nfs-writer
kubectl get pods -l app=rwo-nfs-writer -o wide
```

Expected — **Running on both workers**, despite `ReadWriteOnce`:

```
rwo-nfs-writer-...-aaaaa   1/1   Running   k8s-w1
rwo-nfs-writer-...-bbbbb   1/1   Running   k8s-w2
```

```bash
kubectl exec deploy/rwo-nfs-writer -- tail -4 /data/log.txt
# 10:20:01 node=k8s-w1
# 10:20:02 node=k8s-w2     <- two nodes writing to an "RWO" volume
```

⚠️ **Learned:** NFS has no attach step and no node affinity, so nothing blocks a second
node. Access mode is a contract, not a lock. If you need "one writer" on shared storage,
use **RWOP** (Demo 4) or application-level locking — not RWO.

---

## 7. Demo 2 – ReadOnlyMany (ROX)

**Goal:** publish pre-populated content once and let pods on every node read it —
and see that read-only must be requested explicitly.

`setup-nfs.sh server` already created `/srv/nfs/static/website/index.html` on the NFS
server. This is **static provisioning**: an admin-made PV pointing at existing data.

### 2a. Publish the content as a ROX PV + PVC

```bash
sed "s/NFS_SERVER_IP/$NFS_SERVER/g" manifests/02-rox/a-rox-pv-pvc.yaml | kubectl apply -f -
kubectl get pv rox-website-pv
kubectl get pvc rox-website-pvc
```

```
NAME             CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
rox-website-pv   1Gi        ROX            Retain           Bound    am-demo/rox-website-pvc
```

### 2b. Four nginx pods across both workers, same content

```bash
kubectl apply -f manifests/02-rox/b-rox-readers.yaml
kubectl rollout status deploy/rox-web
kubectl get pods -l app=rox-web -o wide           # 2 on k8s-w1, 2 on k8s-w2

kubectl run curl --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://rox-web.am-demo.svc
```

```html
<h1>Hello from a ReadOnlyMany volume</h1>
```

Now try to modify it from inside a reader:

```bash
kubectl exec deploy/rox-web -- sh -c 'echo hacked > /usr/share/nginx/html/index.html'
# sh: can't create /usr/share/nginx/html/index.html: Read-only file system

kubectl exec deploy/rox-web -- sh -c 'mount | grep nginx/html'
# 192.168.56.10:/srv/nfs/static/website on /usr/share/nginx/html type nfs4 (ro,relatime,vers=4.1,...)
```

✅ **Learned:** many nodes, one dataset, nobody can change it — because the pod asked for
`readOnly: true`.

### 2c. The gotcha — a pod that forgets `readOnly: true`

```bash
kubectl apply -f manifests/02-rox/c-rox-careless-writer.yaml
kubectl wait --for=condition=Ready pod/rox-careless-writer
kubectl exec rox-careless-writer -- sh -c 'echo "oops" > /site/oops.txt && ls -l /site'
```

```
-rw-r--r--  1 root root  ...  about.txt
-rw-r--r--  1 root root  ...  index.html
-rw-r--r--  1 root root    5  oops.txt      <- the write SUCCEEDED on a ROX volume
```

⚠️ **Learned:** `ReadOnlyMany` on the PVC/PV only affects binding. To *guarantee*
read-only, do at least one of:

* `readOnly: true` in every pod's `persistentVolumeClaim` (what 2b does), or
* `nfs.readOnly: true` (or `mountOptions: [ro]`) on the **PV** — enforced for everyone, or
* export the directory `ro` on the NFS server — strongest.

Fix it at the PV level and retry (a PV's volume source is immutable, so recreate it):

```bash
kubectl exec rox-careless-writer -- rm /site/oops.txt
kubectl delete pod rox-careless-writer
kubectl delete deploy rox-web
kubectl delete pvc rox-website-pvc && kubectl delete pv rox-website-pv

# turn on PV-level read-only
sed -i 's|^    # readOnly: true$|    readOnly: true|' manifests/02-rox/a-rox-pv-pvc.yaml
sed "s/NFS_SERVER_IP/$NFS_SERVER/g" manifests/02-rox/a-rox-pv-pvc.yaml | kubectl apply -f -
kubectl apply -f manifests/02-rox/c-rox-careless-writer.yaml
kubectl wait --for=condition=Ready pod/rox-careless-writer
kubectl exec rox-careless-writer -- sh -c 'echo oops > /site/oops.txt'
# sh: can't create /site/oops.txt: Read-only file system     <- now enforced for every pod
kubectl delete pod rox-careless-writer
```

(Content on the NFS server is untouched by deleting the PV — the policy is `Retain`.)

---

## 8. Demo 3 – ReadWriteMany (RWX)

**Goal:** many pods on many nodes read and write the same files at the same time.

```bash
kubectl apply -f manifests/03-rwx/rwx-shared.yaml
kubectl get pvc rwx-pvc                     # Bound immediately (Immediate binding)
kubectl rollout status deploy/rwx-writer
kubectl get pods -l app=rwx-writer -o wide  # 2 per worker
```

Read the shared log from **any** pod — you see writes from **both** nodes:

```bash
kubectl exec deploy/rwx-writer -- tail -8 /shared/events.log
```

```
10:31:01 pod=rwx-writer-...-p1 node=k8s-w1
10:31:01 pod=rwx-writer-...-p2 node=k8s-w2
10:31:02 pod=rwx-writer-...-p3 node=k8s-w1
10:31:02 pod=rwx-writer-...-p4 node=k8s-w2
```

Count writers per node:

```bash
kubectl exec deploy/rwx-writer -- sh -c "awk '{print \$3}' /shared/events.log | sort | uniq -c"
#  42 node=k8s-w1
#  41 node=k8s-w2
```

See where the data physically lives — on the NFS server:

```bash
# on the control plane / NFS server
ls /srv/nfs/kubedata/
# pvc-3f1c...   <- one directory per dynamically provisioned PV
tail -3 /srv/nfs/kubedata/pvc-*/events.log
```

Scale up — new pods join instantly with the same data:

```bash
kubectl scale deploy/rwx-writer --replicas=6
kubectl get pods -l app=rwx-writer -o wide
```

✅ **Learned:** RWX needs a **shared filesystem** (NFS, CephFS, EFS, Azure Files).
Block storage cannot do RWX for filesystems. Kubernetes gives shared access; **your app
must handle concurrent writes** (appending small lines is safe-ish; two processes editing
the same SQLite file is not).

---

## 9. Demo 4 – ReadWriteOncePod (RWOP)

**Goal:** guarantee a single writer in the whole cluster — even on a shared FS where
RWO failed (Demo 1c).

### 4a. First owner

```bash
kubectl apply -f manifests/04-rwop/a-rwop-pvc-writer1.yaml
kubectl wait --for=condition=Ready pod/rwop-writer-1
kubectl get pvc rwop-pvc
kubectl get pod rwop-writer-1 -o wide
```

```
NAME       STATUS   VOLUME        CAPACITY   ACCESS MODES   STORAGECLASS
rwop-pvc   Bound    pvc-9a7e...   1Gi        RWOP           nfs-csi
```

### 4b. Second pod on the SAME node

`rwop-writer-2` uses podAffinity to sit next to writer-1 — the exact situation that
**worked** with RWO in Demo 1a.

```bash
kubectl apply -f manifests/04-rwop/b-rwop-writer2-same-node.yaml
kubectl get pod rwop-writer-2                          # Pending
kubectl describe pod rwop-writer-2 | sed -n '/Events/,$p'
```

```
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node has pod using PersistentVolumeClaim with the same name and ReadWriteOncePod access mode, ...
```

✅ **Learned:** RWO = one **node**; RWOP = one **pod**. Same node, same PVC, still blocked.
And unlike 1c, this is enforced even though the backend is NFS.

### 4c. (Optional) Preemption — a more important pod takes over

```bash
kubectl delete pod rwop-writer-2
kubectl apply -f manifests/04-rwop/c-rwop-preempt.yaml
kubectl get pods -w          # watch rwop-writer-1 terminate, rwop-vip start (Ctrl-C)
kubectl exec rwop-vip -- tail -4 /data/owner.log
```

```
10:40:05 rwop-writer-1 on k8s-w2 owns the volume
10:40:10 rwop-writer-1 on k8s-w2 owns the volume
10:40:21 VIP rwop-vip on k8s-w1 owns the volume now
```

✅ **Learned:** the scheduler treats an RWOP volume like an exclusive resource and can
preempt a lower-priority owner. Data survived the hand-over because it lives on NFS.

### When to use RWOP

* Single-writer databases / apps that corrupt data with two writers
  (SQLite, Prometheus TSDB, many embedded DBs) — especially on shared storage.
* Deployment rolling updates: with RWOP the new pod waits for the old one to release
  the volume. Use `strategy: Recreate` to avoid a stuck rollout.

---

## 10. Side-by-side results

| Scenario | RWO (local-path) | RWO (NFS) | ROX (NFS) | RWX (NFS) | RWOP (NFS-CSI) |
|---|---|---|---|---|---|
| 2+ pods, same node | ✅ Demo 1a | ✅ | ✅ | ✅ | ❌ Demo 4b |
| 2+ pods, different nodes | ❌ Demo 1b | ⚠️ ✅ *not enforced* Demo 1c | ✅ Demo 2b | ✅ Demo 3 | ❌ |
| Pod can write | ✅ | ✅ | only if `readOnly` missing ⚠️ Demo 2c | ✅ | ✅ |
| Enforced by | PV node affinity / attach | nothing | pod/PV `readOnly` flag | — | scheduler + kubelet |

---

## 11. Which mode should I use?

```
Does more than one pod need the data?
├── No ──► Must it be IMPOSSIBLE for a 2nd pod to mount it?
│          ├── Yes ─► RWOP   (CSI driver required)
│          └── No  ─► RWO    (default; StatefulSet per-replica disks)
└── Yes ─► Do they need to write?
           ├── No  ─► ROX    + readOnly: true   (shared config, ML models, static sites)
           └── Yes ─► RWX    (shared FS: NFS / CephFS / EFS / Azure Files)
```

Rules of thumb:

* **StatefulSets** (databases, Kafka, etcd) → RWO per replica via `volumeClaimTemplates`, or RWOP for extra safety.
* **Shared uploads / CMS media / CI caches** → RWX.
* **Published, versioned content** → ROX with `readOnly: true` (or a `ro` export).
* Cloud block disks (EBS, PD, Azure Disk) **cannot** do RWX for filesystems — pick a file service.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `mount.nfs: access denied by server` | client IP not in `ALLOWED_CIDR` | re-run `server` with the right `ALLOWED_CIDR`, then `exportfs -ra` |
| Pod stuck `ContainerCreating`, event `bad option; ... need a /sbin/mount.<type> helper` | `nfs-common` missing on that worker | `sudo ./scripts/setup-nfs.sh client <IP>` on that node |
| `nfs-csi` PVC stays `Pending` | csi-nfs-controller not running / wrong server IP | `kubectl -n kube-system logs deploy/csi-nfs-controller -c nfs`; check `kubectl get sc nfs-csi -o yaml` |
| `local-path` PVC `Pending` | normal until a pod uses it (WaitForFirstConsumer) | create the pod |
| Pods only on one worker | other worker `NotReady` or tainted | `kubectl get nodes`, `kubectl describe node` |
| ROX PVC `Pending` | PV/PVC name or namespace mismatch in `claimRef` | both must be `am-demo/rox-website-pvc` |
| Deployment rollout stuck with RWOP | new pod can't get volume until old pod is gone | use `strategy: { type: Recreate }` |

Handy commands:

```bash
kubectl get pv,pvc -A
kubectl describe pvc <name>
kubectl get events --sort-by=.lastTimestamp | tail -20
sudo exportfs -v                 # on the NFS server
mount | grep nfs                 # on a worker
```

---

## 13. Cleanup

```bash
./scripts/cleanup.sh            # demo namespace, ROX PV, PriorityClass
./scripts/cleanup.sh --all      # + StorageClass nfs-csi and local-path provisioner
```

On the NFS server, leftover dynamic volumes (if any) are under `/srv/nfs/kubedata/`.
To remove NFS entirely:

```bash
sudo rm /etc/exports.d/k8s-demo.exports && sudo exportfs -ra
sudo systemctl disable --now nfs-kernel-server
```

---

### Versions used

| Component | Version |
|---|---|
| Kubernetes | v1.36 (kubeadm, pkgs.k8s.io) — change with `K8S_MINOR` |
| CNI | Flannel (latest) |
| csi-driver-nfs | v4.13.2 — change with `CSI_NFS_VERSION` |
| local-path-provisioner | v0.0.37 — change with `LOCAL_PATH_VERSION` |
| OS | Ubuntu 22.04 / 24.04 |
