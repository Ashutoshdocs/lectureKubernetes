# Production-Grade Shared Storage: Writer → Reader on an RWX PVC

A production rewrite of the classic **writer-pod + reader-pod sharing
`/data/shared`** demo. The original teaches the idea; this shows how you'd
actually run it: a real shared volume, hardened workloads, and the reader locked
to read-only.

## Why the original isn't production-ready (and what changed)

| Concern | Original (writer-pod / reader-pod) | This demo |
|---|---|---|
| Shared volume | `hostPath: /data/shared` — **node-local** | **RWX PVC** (NFS now, EFS/Azure Files/Filestore in cloud) |
| Reschedule to another node | breaks — different/empty dir | works — network volume follows the pod |
| Workload type | bare **Pods** (no self-heal) | **Deployments** (replicas, rollouts, self-heal) |
| Identity of data | anyone writes | reader mounts **`readOnly`**; only writers write |
| Container security | root, full caps, writable rootfs | non-root uid 1000, **drop ALL caps**, `readOnlyRootFilesystem`, seccomp `RuntimeDefault` |
| Namespace policy | none | `restricted` **Pod Security** enforced |
| Resource safety | none | CPU/memory **requests & limits** |
| Health | none | liveness (writer) / readiness (reader) probes |
| Data safety on delete | n/a | PV `reclaimPolicy: Retain` |

> **The core production lesson:** to share files *between pods*, you need a
> `ReadWriteMany` volume, and you decouple the workload from the storage with a
> **PVC**. `hostPath` looks like it works on a single-node lab and then fails the
> moment a pod lands on a different node.

---

## Layout
```
k8s-shared-storage-prod/
├── README.md
├── verify.sh                        # up / prove / harden / clean
├── 00-namespace.yaml                # namespace + restricted Pod Security
├── 10-storage/
│   ├── nfs-server.yaml              # self-contained RWX backend (dev)
│   ├── shared-pv-pvc.yaml           # RWX PV + PVC (the shared volume)
│   └── storageclass-swap.md         # swap NFS -> EFS/Azure Files/Filestore
├── 20-workloads/
│   ├── writer-deployment.yaml       # 2 writers, hardened, RW mount
│   └── reader-deployment.yaml       # 2 readers, hardened, READ-ONLY mount
└── 30-dev-hostpath/
    └── hostpath-variant.yaml        # original pattern, corrected, DEV ONLY
```

## Prerequisites
- `kubectl` + a cluster. Runs on kind/minikube (single node) or any multi-node
  cluster — the RWX/NFS backend means it works across nodes too.
- No external storage needed: the demo runs its own NFS server. For real
  clusters, see `10-storage/storageclass-swap.md`.

## Quick start
```bash
chmod +x verify.sh
./verify.sh up       # deploy everything
./verify.sh prove    # shared writes + read-only enforcement
./verify.sh harden   # show the security context is real
./verify.sh clean
```

---

## Step 1 — Deploy
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-storage/nfs-server.yaml
kubectl -n shared-storage wait --for=condition=Available deploy/nfs-server --timeout=180s
kubectl apply -f 10-storage/shared-pv-pvc.yaml
kubectl apply -f 20-workloads/writer-deployment.yaml
kubectl apply -f 20-workloads/reader-deployment.yaml
kubectl -n shared-storage get pvc,pods -o wide
```
`shared-pvc` should be `Bound`; 2 writers + 2 readers `Running`.

## Step 2 — Prove concurrent sharing (RWX)
```bash
R=$(kubectl -n shared-storage get pod -l app.kubernetes.io/name=reader -o jsonpath='{.items[0].metadata.name}')
kubectl -n shared-storage exec "$R" -- sh -c 'awk "{print \$4}" /shared/data.txt | sort -u'
```
**✅** Two distinct writer pod names appear — both writer replicas (possibly on
different nodes) append to the **same file** on the shared volume.

## Step 3 — Prove the reader is read-only
```bash
kubectl -n shared-storage exec "$R" -- sh -c 'echo hack > /shared/data.txt || echo BLOCKED'
```
**✅** Output:
```
sh: can't create /shared/data.txt: Read-only file system
BLOCKED
```
The consumer physically cannot corrupt the shared data — enforced by
`readOnly: true` on both the volume and the mount.

## Step 4 — Prove the security hardening is real
```bash
W=$(kubectl -n shared-storage get pod -l app.kubernetes.io/name=writer -o jsonpath='{.items[0].metadata.name}')
kubectl -n shared-storage exec "$W" -- id                       # uid=1000 gid=1000 (not root)
kubectl -n shared-storage exec "$W" -- sh -c 'echo x > /oops || echo "/ is read-only"'
```
**✅** Runs as uid 1000, and the **root filesystem is read-only** — writes land
only on the mounted volume. The namespace enforces the `restricted` Pod Security
profile, so a pod that tried to run privileged/root would be **rejected at
admission**. Test that:
```bash
kubectl -n shared-storage run bad --image=busybox --overrides='{"spec":{"containers":[{"name":"bad","image":"busybox","securityContext":{"privileged":true}}]}}' --command -- sleep 1
# Error: violates PodSecurity "restricted:latest": privileged ... allowPrivilegeEscalation != false ...
```

## Step 5 — Prove resilience (self-heal + data persistence)
```bash
# kill a writer pod; the Deployment recreates it, data keeps flowing
kubectl -n shared-storage delete pod -l app.kubernetes.io/name=writer --wait=false
kubectl -n shared-storage get pods -w    # watch a new writer come up (Ctrl-C to stop)
# the file kept all prior lines because it lives on the RWX volume, not the pod
kubectl -n shared-storage exec "$R" -- sh -c 'wc -l /shared/data.txt'
```

---

## Appendix A — `hostPath` `type` field (from your notes)

Used only in `30-dev-hostpath/` (dev/lab). Always set `type` explicitly:

| `type` | Meaning |
|--------|---------|
| `""` (unset) | no check — mounts whatever is there, or nothing |
| `Directory` | directory **must already exist** (fails otherwise) |
| `DirectoryOrCreate` | create the directory (0755) if missing ← safe default |
| `File` | file must exist |
| `FileOrCreate` | create the file if missing |

The original `behaviour_check` used `type: Directory`, which fails on a fresh
node where `/data/shared` doesn't exist yet. The corrected dev variant uses
`DirectoryOrCreate`.

Run the dev variant on a single-node cluster:
```bash
kubectl apply -f 30-dev-hostpath/hostpath-variant.yaml
kubectl -n shared-storage logs -f reader-pod
```

## Appendix B — Production checklist for shared storage
- [ ] Use an **RWX** class (`efs-sc`, `azurefile-csi`, Filestore, CephFS) — never
      hostPath for app data.
- [ ] Decouple via a **PVC**; keep `storageClassName`/PV out of the workload spec.
- [ ] Reader/consumer mounts **`readOnly: true`**.
- [ ] `reclaimPolicy: Retain` for data you can't lose; back it up separately —
      RWX ≠ backup.
- [ ] Non-root, `drop: ["ALL"]`, `readOnlyRootFilesystem`, seccomp
      `RuntimeDefault`; enforce `restricted` PSA on the namespace.
- [ ] Requests **and** limits on every container.
- [ ] Liveness/readiness probes; run workloads as Deployments/StatefulSets, not
      bare Pods.
- [ ] Set `fsGroup` so non-root pods can write to the mounted volume.

## Cleanup
```bash
./verify.sh clean
# or
kubectl delete namespace shared-storage
kubectl delete pv shared-nfs-pv --ignore-not-found
```
