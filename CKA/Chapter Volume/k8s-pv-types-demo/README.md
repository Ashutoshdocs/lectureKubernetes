# Kubernetes PV/PVC — 3 Storage Backends, 3 Pods, 2 Claims

Three PV/PVC types side by side — **hostPath**, **Azure CSI**, **NFS** — with
three pods wired so that **two pods share one PVC and a third uses another**, and
commands that **prove data written inside a pod or outside it (node / NFS server
/ Azure share) is reflected on both sides**.

---

## Layout at a glance

```
Backend      PV/PVC                 Access   Pods mounting it       "Outside" =
---------    --------------------   ------   --------------------   ---------------------------
hostPath     hostpath-pv/-pvc  (#1) RWO      pod-a  +  pod-b        a folder on the node
NFS          nfs-pv/-pvc       (#2) RWX      pod-c                  the NFS server's /exports
Azure Files  azurefile-pvc (dynamic) RWX     pod-azure              the Azure Files share (Portal)
```

- **3 pods:** `pod-a`, `pod-b`, `pod-c` (+ `pod-azure` on AKS).
- **2 claims in play:** `hostpath-pvc` (shared by pod-a & pod-b) and `nfs-pvc`
  (pod-c). That's the "3 pods, 2 different PV/PVC" arrangement — and sharing #1
  across two pods is what lets us prove cross-pod reflection.
- **3 backend types** so you can compare how node-local, network-file, and
  cloud-CSI storage each behave.

```
k8s-pv-types-demo/
├── README.md
├── verify.sh                         # one script: setup / hostpath / nfs / azure / mounts / clean
├── 00-namespace.yaml
├── 10-hostpath/
│   ├── hostpath-pv-pvc.yaml          # PVC #1 (RWO, node-local)
│   └── hostpath-pods.yaml            # pod-a + pod-b share PVC #1
├── 20-nfs/
│   ├── nfs-server.yaml               # in-cluster NFS server (the "outside")
│   └── nfs-pv-pvc-pod.yaml           # PVC #2 (RWX) + pod-c
└── 30-azure-csi/
    ├── azurefile-csi.yaml            # Azure File CSI, dynamic, RWX (AKS)
    └── azuredisk-csi-static.yaml     # Azure Disk CSI, static, RWO (alternative)
```

---

## Prerequisites

- `kubectl` + a cluster. **hostPath and NFS parts run on any single-node cluster**
  (kind / minikube / Docker Desktop).
- **Azure CSI part needs AKS** (or a cluster with the Azure CSI drivers). It's
  written to be correct and copy-paste-ready; on a local cluster the Azure PVC
  simply stays `Pending`, which is expected — skip it there.

Quickest path:
```bash
chmod +x verify.sh
./verify.sh setup && ./verify.sh hostpath && ./verify.sh nfs && ./verify.sh mounts
```
Everything below is the manual version of that, with the proof output called out.

---

## Step 1 — Namespace + NFS server
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 20-nfs/nfs-server.yaml
kubectl -n pv-types wait --for=condition=Ready pod -l app=nfs-server --timeout=180s
```

## Step 2 — hostPath: PVC #1 shared by pod-a and pod-b
```bash
kubectl apply -f 10-hostpath/hostpath-pv-pvc.yaml
kubectl apply -f 10-hostpath/hostpath-pods.yaml
kubectl -n pv-types wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=120s
kubectl -n pv-types get pvc hostpath-pvc          # STATUS: Bound
```

### ✅ Proof 1 — write **inside** pod-a → read **inside** pod-b
```bash
kubectl -n pv-types exec pod-a -- sh -c 'echo "hello from pod-a @ $(date -u)" > /data/shared.txt'
kubectl -n pv-types exec pod-b -- cat /data/shared.txt
```
pod-b prints the line pod-a wrote — same PVC, one volume, two pods.

### ✅ Proof 2 — write **outside** (the node folder) → read **inside** the pod
`hostPath` maps to `/mnt/data/hostpath-demo` on the node, so "outside" is just a
node shell:
```bash
# kind (node is a docker container):
NODE=$(kubectl -n pv-types get pod pod-a -o jsonpath='{.spec.nodeName}')
docker exec "$NODE" sh -c 'echo "written on the NODE @ $(date -u)" >> /mnt/data/hostpath-demo/shared.txt'

# minikube:
minikube ssh -- 'sudo sh -c "echo written-on-node >> /mnt/data/hostpath-demo/shared.txt"'

# now read it from inside either pod:
kubectl -n pv-types exec pod-a -- cat /data/shared.txt
```
The node-written line shows up inside the pod. Inside == outside. ✅

## Step 3 — NFS: PVC #2 used by pod-c (the 3rd pod)
```bash
kubectl apply -f 20-nfs/nfs-pv-pvc-pod.yaml
kubectl -n pv-types wait --for=condition=Ready pod/pod-c --timeout=120s
kubectl -n pv-types get pvc nfs-pvc               # STATUS: Bound
```

### ✅ Proof 3 — write **inside** pod-c → read **outside** on the NFS server
```bash
kubectl -n pv-types exec pod-c -- sh -c 'echo "from pod-c @ $(date -u)" > /data/hello.txt'
SRV=$(kubectl -n pv-types get pod -l app=nfs-server -o jsonpath='{.items[0].metadata.name}')
kubectl -n pv-types exec "$SRV" -- cat /exports/hello.txt
```

### ✅ Proof 4 — write **outside** (on NFS server) → read **inside** pod-c
```bash
kubectl -n pv-types exec "$SRV" -- sh -c 'echo "from nfs-server @ $(date -u)" > /exports/reverse.txt'
kubectl -n pv-types exec pod-c -- cat /data/reverse.txt
```
Data flows both directions across the network share. ✅

## Step 4 — Azure CSI (on AKS)
```bash
kubectl apply -f 30-azure-csi/azurefile-csi.yaml
kubectl -n pv-types wait --for=condition=Ready pod/pod-azure --timeout=180s
kubectl -n pv-types get pvc azurefile-pvc         # Bound; a share is auto-provisioned
kubectl -n pv-types exec pod-azure -- cat /data/from-pod.txt
```
### ✅ Proof 5 — inside ↔ outside for Azure Files
- **Inside → outside:** the pod wrote `/data/from-pod.txt`. Open the Azure
  Portal → the auto-created Storage Account → **File shares** → you'll see the
  same file. Or:
  ```bash
  az storage file list --account-name <acct> --share-name <share> -o table
  ```
- **Outside → inside:** upload a file to that share (Portal, Storage Explorer, or
  `az storage file upload`), then:
  ```bash
  kubectl -n pv-types exec pod-azure -- ls -l /data
  ```
  it appears inside the pod. ✅

> Prefer static Azure **Disk** (RWO block) instead? Use
> `30-azure-csi/azuredisk-csi-static.yaml` — fill in your managed-disk resource
> ID first (instructions are in the file header).

---

## See the mount points (how each backend actually mounts)
```bash
./verify.sh mounts
# or manually, per pod:
kubectl -n pv-types exec pod-a     -- df -h /data
kubectl -n pv-types exec pod-a     -- sh -c 'cat /proc/mounts | grep /data'
kubectl -n pv-types exec pod-c     -- sh -c 'cat /proc/mounts | grep /data'   # shows nfs4
kubectl -n pv-types exec pod-azure -- sh -c 'mount | grep /data'              # shows cifs (Azure Files)
```
What you'll notice in `/proc/mounts`:

| Pod | Backend | Mount type you'll see |
|-----|---------|-----------------------|
| pod-a / pod-b | hostPath | the node's own fs (e.g. `overlay` / `ext4`) bind-mounted |
| pod-c | NFS | `nfs4` with the server address |
| pod-azure | Azure Files | `cifs` (SMB) to the storage account |

Also handy — see which pod is bound to which volume and where it's attached:
```bash
kubectl -n pv-types get pvc -o wide
kubectl get pv -o custom-columns=\
NAME:.metadata.name,TYPE:.spec.csi.driver,HOSTPATH:.spec.hostPath.path,\
NFS:.spec.nfs.server,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase
kubectl -n pv-types describe pod pod-a | sed -n '/Volumes:/,/Events:/p'
```

---

## What each backend teaches

- **hostPath** — data lives on one node; great for learning/single-node, useless
  for multi-node scheduling (the pod must return to the same node to see its
  data). "Outside" is a node shell.
- **NFS** — a real network filesystem: `ReadWriteMany`, survives pods moving
  between nodes, reflects instantly in both directions. "Outside" is the NFS
  server.
- **Azure CSI** — production cloud storage via the CSI standard. Azure **Files**
  (`cifs`/SMB) → RWX & shareable; Azure **Disk** (block) → RWO, single node.
  "Outside" is the Azure Storage account you can see in the Portal.

## Cleanup
```bash
./verify.sh clean
# or
kubectl delete namespace pv-types
kubectl delete pv hostpath-pv nfs-pv azuredisk-pv --ignore-not-found
```
