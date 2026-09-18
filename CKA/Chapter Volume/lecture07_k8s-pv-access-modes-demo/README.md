# Kubernetes PV Access Modes — Proven, Not Just Explained

RWO vs ROX vs RWX (+ the new RWOP), demonstrated with runnable manifests.

This repo doesn't just *state* what the access modes mean — each one ships with
an experiment whose output is the proof. The single most important thing to
internalize:

> **Access modes are enforced at the NODE boundary, not the pod boundary**
> (except the newer `ReadWriteOncePod`). And an access mode is only as real as
> the storage backend underneath it — a block disk physically can't do RWX no
> matter what you write in the YAML.

---

## The four access modes

| Mode | Short | Real meaning | Typical backend |
|------|-------|--------------|-----------------|
| `ReadWriteOnce` | **RWO** | RW by a **single node** at a time (many pods on that node OK) | Block: EBS, GCE PD, Azure Disk, local-path |
| `ReadOnlyMany` | **ROX** | Read-only, mounted by **many nodes** at once | NFS, CephFS, pre-populated volumes |
| `ReadWriteMany` | **RWX** | RW by **many nodes** simultaneously | Shared FS: NFS, CephFS, Azure Files, EFS |
| `ReadWriteOncePod` | **RWOP** | RW by **exactly one pod** cluster-wide (k8s 1.22+) | Any CSI driver that supports it |

Two myths this demo kills:

1. **"RWO means one pod."** False. It means one *node*. Experiment 30-A runs
   two pods on the same node sharing one RWO volume happily.
2. **"I set `ReadWriteMany` so now many pods can write."** False if your
   StorageClass hands you a block disk — it will bind, then fail to attach on a
   second node. The access mode is a *request/label used for matching*; the
   backend decides what's physically possible. That's why this demo runs a real
   NFS server for the RWX/ROX parts.

---

## What's in here

```
k8s-pv-access-modes-demo/
├── README.md
├── run-demo.sh                     # one script to drive every experiment
├── 00-nfs-server/
│   ├── namespace.yaml              # namespace: pv-demo
│   └── nfs-server.yaml             # in-cluster NFS server (backs RWX + ROX)
├── 10-rwx/
│   ├── rwx-pv-pvc.yaml             # NFS PV/PVC, accessMode ReadWriteMany
│   └── rwx-writers.yaml            # 3 pods writing the SAME file at once
├── 20-rox/
│   ├── rox-seed-job.yaml           # seed data once (RW), then seal it
│   └── rox-readers.yaml            # 3 read-only pods; writes get rejected
├── 30-rwo/
│   ├── rwo-pvc.yaml                # default StorageClass block volume, RWO
│   ├── rwo-A-same-node-two-pods.yaml   # PROOF: 2 pods, 1 node = OK
│   └── rwo-B-other-node-blocked.yaml   # PROOF: pod on other node = Multi-Attach error
└── 40-bonus/
    └── rwop.yaml                   # ReadWriteOncePod = truly one pod
```

---

## Prerequisites

- A Kubernetes cluster + `kubectl` pointed at it.
- **For the full RWO proof (part B) you need ≥ 2 worker nodes.** Everything
  else works on a single-node kind/minikube/Docker-Desktop cluster.
- The RWX/ROX demos run their own NFS server in-cluster, so **no external
  storage is required**.

Quick 2-node cluster if you need one:

```bash
kind create cluster --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

---

## Run it

```bash
chmod +x run-demo.sh

./run-demo.sh setup    # namespace + NFS server
./run-demo.sh rwx      # prove ReadWriteMany
./run-demo.sh rox      # prove ReadOnlyMany
./run-demo.sh rwo      # prove ReadWriteOnce (part B needs 2+ nodes)
./run-demo.sh rwop     # bonus: prove ReadWriteOncePod
./run-demo.sh clean    # tear everything down
```

Or apply manifests by hand — see each section below for the exact commands and,
crucially, **what output counts as proof**.

---

## 10 — RWX (ReadWriteMany): many pods write the same file at once

```bash
kubectl apply -f 10-rwx/rwx-pv-pvc.yaml
kubectl apply -f 10-rwx/rwx-writers.yaml
kubectl -n pv-demo get pods -l app=rwx-writers -o wide     # ideally on different nodes
```

**Proof — one shared file holds interleaved writes from all 3 pods:**

```bash
POD=$(kubectl -n pv-demo get pod -l app=rwx-writers -o jsonpath='{.items[0].metadata.name}')
kubectl -n pv-demo exec "$POD" -- sh -c 'awk "{print \$4}" /data/shared.log | sort -u'
```

Expected — three distinct `pod=...` names, e.g.:

```
pod=rwx-writers-6c9f8b7d5-2xk9p
pod=rwx-writers-6c9f8b7d5-8t4mn
pod=rwx-writers-6c9f8b7d5-q7wlz
```

All three pods, potentially on different nodes, are appending to **the same
file on the same volume simultaneously**. That is RWX. ✅

---

## 20 — ROX (ReadOnlyMany): read succeeds, write is physically rejected

```bash
kubectl apply -f 20-rox/rox-seed-job.yaml          # write the dataset once
kubectl -n pv-demo wait --for=condition=complete job/rox-seed --timeout=120s
kubectl apply -f 20-rox/rox-readers.yaml           # 3 read-only consumers
```

**Proof — every reader reads the data but its write attempt fails:**

```bash
kubectl -n pv-demo logs -l app=rox-readers --prefix
```

Expected per pod:

```
[rox-readers-...] READ test:
v1.0.0
[rox-readers-...] WRITE test (expected to FAIL):
  EXPECTED: write blocked -> /data/HACKED: Read-only file system
```

`readOnly: true` on the volumeMount makes the kubelet mount the filesystem
read-only, so the kernel rejects the write. Many nodes, read-only, enforced. ✅

---

## 30 — RWO (ReadWriteOnce): one NODE, not one pod

### Part A — two pods on the SAME node share it (works)

```bash
kubectl apply -f 30-rwo/rwo-pvc.yaml
kubectl apply -f 30-rwo/rwo-A-same-node-two-pods.yaml
kubectl -n pv-demo get pods -l app=rwo-same-node -o wide
```

**Proof:** both replicas reach `Running` on the **same node** and both write to
`/data/rwo.log`. This is the myth-buster: **RWO does not mean a single pod.** ✅

### Part B — a pod on ANOTHER node is blocked (needs ≥ 2 nodes)

```bash
kubectl apply -f 30-rwo/rwo-B-other-node-blocked.yaml
kubectl -n pv-demo get pods -l app=rwo-other-node -o wide   # stuck ContainerCreating
POD=$(kubectl -n pv-demo get pod -l app=rwo-other-node -o jsonpath='{.items[0].metadata.name}')
kubectl -n pv-demo describe pod "$POD" | grep -iA3 multi-attach
```

**Proof — the attach is refused:**

```
Warning  FailedAttachVolume   Multi-Attach error for volume "pvc-xxxx"
         Volume is already exclusively attached to one node and can't be
         attached to another
```

The volume is locked to node A; node B can't have it. That node boundary *is*
RWO. ✅ (Single-node cluster? Part B simply can't trigger — which is itself the
point: RWO only ever constrains you across nodes.)

---

## 40 — BONUS: RWOP (ReadWriteOncePod): truly one pod

```bash
kubectl apply -f 40-bonus/rwop.yaml
kubectl -n pv-demo get pods -l app=rwop-demo -o wide
```

**Proof:** the Deployment asks for 2 replicas pinned to the same node, yet only
**one** pod is `Running`; the other stays `Pending` because the volume is
already used by a pod — even on the same node. Stronger than RWO. ✅

---

## Mental model to walk away with

- The access mode on a PVC is a **matchmaking label + a runtime constraint**,
  not a magic capability. Binding checks the label; the CSI/attach layer and the
  filesystem enforce the behavior.
- **The backend sets the ceiling.** Block storage → RWO/RWOP only. Shared
  filesystem (NFS/CephFS/EFS/Azure Files) → can also do RWX/ROX.
- **Count nodes, not pods** for RWO/ROX/RWX. Count pods only for RWOP.
- A PV can advertise several modes; each PVC picks exactly one *set* at bind
  time and each pod chooses read-only vs read-write at mount time.

## Cleanup

```bash
./run-demo.sh clean
# or
kubectl delete namespace pv-demo
kubectl delete pv rwx-nfs-pv rox-nfs-pv --ignore-not-found
```
