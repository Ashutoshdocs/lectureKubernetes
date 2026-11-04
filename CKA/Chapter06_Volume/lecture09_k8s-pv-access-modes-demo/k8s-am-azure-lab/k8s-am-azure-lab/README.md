# Kubernetes Volume Access Modes Practical on Azure — 4 VM Architecture

## Complete Hands-On Lab: RWO · ROX · RWX · RWOP

This practical demonstrates **what each PersistentVolume access mode really means** on a
**3-node Kubernetes cluster (1 control plane + 2 workers)** with a **dedicated NFS server**,
all running on **4 Azure VMs**.

We will use:

```text
VM-1 → Dedicated NFS Server
VM-2 → Kubernetes Control Plane
VM-3 → Kubernetes Worker 1
VM-4 → Kubernetes Worker 2
```

Two workers are essential: access modes are about **nodes**, so we need at least two
nodes that can run pods to show "one node" versus "many nodes".

---

# 1. Lab Architecture

```text
                              AZURE VNET 10.0.0.0/16
                              SUBNET     10.0.1.0/24
                                       |
       +-------------------+-----------+-----------+-------------------+
       |                   |                       |                   |
       v                   v                       v                   v
  +---------+        +-----------+          +-----------+        +-----------+
  |  VM-1   |        |   VM-2    |          |   VM-3    |        |   VM-4    |
  |   NFS   |        |    K8s    |          |    K8s    |        |    K8s    |
  | Server  |        |  Control  |          |  Worker 1 |        |  Worker 2 |
  |         |        |   Plane   |          |           |        |           |
  |10.0.1.4 |        | 10.0.1.5  |          | 10.0.1.6  |        | 10.0.1.7  |
  +----+----+        +-----+-----+          +-----+-----+        +-----+-----+
       |                   |                      |                    |
       |                   +----------K8s API-----+--------------------+
       |                                          |                    |
       +-------------------- TCP 2049 (NFS) ------+--------------------+
       |
  /srv/nfs/k8s/
     ├── rwo/    ← RWO-on-NFS gotcha demo
     ├── rox/    ← pre-populated website (ROX demo)
     ├── rwx/    ← shared log (RWX demo)
     └── rwop/   ← single-owner volume (RWOP demo)

  k8s-worker-1 also has a LOCAL disk folder:
     /mnt/disks/rwo   ← real single-node RWO volume (stands in for Azure Disk)
```

The control plane keeps its default `NoSchedule` taint, so **all demo pods run on
VM-3 and VM-4 only**.

---

# 2. VM Roles

| VM | Azure name | Private IP | Size | Role |
|---|---|---|---|---|
| VM-1 | `nfs-vm` | `10.0.1.4` | Standard_B1s | Dedicated NFS Server |
| VM-2 | `k8s-control-plane` | `10.0.1.5` | Standard_B2s | Kubernetes Control Plane |
| VM-3 | `k8s-worker-1` | `10.0.1.6` | Standard_B2s | Kubernetes Worker 1 |
| VM-4 | `k8s-worker-2` | `10.0.1.7` | Standard_B2s | Kubernetes Worker 2 |

> On Azure the VM name becomes the Linux hostname, and therefore the Kubernetes
> **node name**. The manifests use `k8s-worker-1` / `k8s-worker-2` in `nodeSelector`,
> so keep these names (or edit the YAML).

---

# 3. The Four Access Modes

| Mode | Short | Real meaning | Typical backend |
|---|---|---|---|
| `ReadWriteOnce` | **RWO** | RW by a **single node** at a time (many pods *on that node* OK) | Block: Azure Disk, EBS, GCE PD, local disk |
| `ReadOnlyMany` | **ROX** | Read-only, mounted by **many nodes** at once | NFS, CephFS, pre-populated volumes |
| `ReadWriteMany` | **RWX** | RW by **many nodes** simultaneously | Shared FS: NFS, CephFS, Azure Files, EFS |
| `ReadWriteOncePod` | **RWOP** | RW by **exactly one pod** cluster-wide (k8s 1.22+, GA 1.29) | CSI drivers only |

Pictures to keep in mind:

```text
RWO                      ROX                       RWX                      RWOP
---                      ---                       ---                      ----
 Node 1                   Node 1   Node 2           Node 1   Node 2          Node 1
 ┌──────────┐             ┌─────┐  ┌─────┐          ┌─────┐  ┌─────┐         ┌─────┐
 │PodA PodB │             │PodA │  │PodB │          │PodA │  │PodB │         │PodA │
 └────┬─────┘             └──┬──┘  └──┬──┘          └──┬──┘  └──┬──┘         └──┬──┘
      │ rw                   │ ro     │ ro             │ rw     │ rw            │ rw
      v                      v        v                v        v               v
   [Volume]                   [Volume]                  [Volume]             [Volume]

 Node 2 → ✗               Nobody writes             Everybody writes       Any 2nd pod → ✗
                                                                            (even same node)
```

---

# 4. What We Will Demonstrate

```text
Create 4 VMs (one PowerShell script)
    ↓
Verify NFS server + clients
    ↓
Build cluster (kubeadm + Calico VXLAN)
    ↓
RWO  → 3 pods, 1 node OK  |  pod on 2nd node blocked  |  NFS gotcha
    ↓
ROX  → 4 readers on 2 nodes  |  writes fail  |  "forgot readOnly" gotcha
    ↓
RWX  → 4 writers on 2 nodes, one shared file
    ↓
RWOP → 1 pod only, even on the same node  |  hand-over
    ↓
Binding → PVC ↔ PV matching by access mode
```

---

# 5. Prerequisites

You need:

- An Azure subscription
- Azure CLI installed and logged in: `az login`
- PowerShell 5.1 (Windows) or PowerShell 7 (Windows / macOS / Linux)
- **7 vCPU of B-series quota** in the region (1 × B1s + 3 × B2s)
- An SSH client (`ssh` / `scp` are built into Windows 10+)

Check quota:

```powershell
az vm list-usage --location centralindia --query "[?contains(name.value,'standardBSFamily')]" -o table
```

> Azure free-trial subscriptions often allow only 4 vCPU per region. If VM creation fails
> with a quota error, request an increase or pick another region in the script.

Password rule for the VMs: **12–72 characters, with 3 of: lowercase, uppercase, digit, special**.

---

# 6. Lab Files

```text
k8s-am-azure-lab/
├── create-lab-vms.ps1               # creates RG, VNet, NSG and the 4 VMs (+ cloud-init)
├── delete-lab.ps1                   # deletes everything
├── README.md
├── scripts/
│   ├── 01-init-control-plane.sh     # kubeadm init + Calico VXLAN + join command
│   ├── 02-install-nfs-csi-driver.sh # NFS CSI driver (needed for RWOP only)
│   └── 99-cleanup-demos.sh
└── manifests/
    ├── 00-namespace.yaml
    ├── 01-rwo/      rwo-local-pv-pvc.yaml  rwo-deployment.yaml  rwo-intruder-pod.yaml
    │                rwo-nfs-pv-pvc.yaml    rwo-nfs-two-nodes.yaml
    ├── 02-rox/      rox-pv-pvc.yaml  rox-nginx.yaml  rox-careless-pod.yaml  rox-pv-pvc-enforced.yaml
    ├── 03-rwx/      rwx-pv-pvc.yaml  rwx-deployment.yaml
    ├── 04-rwop/     rwop-pv-pvc.yaml  rwop-pod-1.yaml  rwop-pod-2.yaml  rwop-pod-3.yaml
    └── 05-binding/  mismatch-pv.yaml  mismatch-pvc-rwx.yaml  mismatch-pvc-rwo.yaml
```

---

# 7. Create the 4 VMs

On your laptop, in the lab folder:

```powershell
.\create-lab-vms.ps1
```

If PowerShell blocks the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create-lab-vms.ps1
```

The script performs:

```text
[1/8] Resource Group        rg-k8s-access-modes
[2/8] VNet + Subnet         10.0.0.0/16 , 10.0.1.0/24
[3/8] NSG                   only SSH (22) open from the Internet
[4/8] nfs-vm                10.0.1.4   + cloud-init: NFS server
[5/8] k8s-control-plane     10.0.1.5   + cloud-init: containerd, kubeadm
[6/8] k8s-worker-1          10.0.1.6   + cloud-init: containerd, kubeadm
[7/8] k8s-worker-2          10.0.1.7   + cloud-init: containerd, kubeadm
[8/8] waits until cloud-init finished on all 4 VMs
```

Expected at the end:

```text
      nfs-vm ... ready
      k8s-control-plane ... ready
      k8s-worker-1 ... ready
      k8s-worker-2 ... ready

VirtualMachine     PublicIPAddresses    PrivateIPAddresses
-----------------  -------------------  --------------------
k8s-control-plane  20.x.x.x             10.0.1.5
k8s-worker-1       20.x.x.x             10.0.1.6
k8s-worker-2       20.x.x.x             10.0.1.7
nfs-vm             20.x.x.x             10.0.1.4
```

Total time: about **10–15 minutes**.

---

# 8. What cloud-init Already Did

## On `nfs-vm`

```text
apt install nfs-kernel-server
mkdir /srv/nfs/k8s/{rwo,rox,rwx,rwop}
write /srv/nfs/k8s/rox/index.html and about.txt   (pre-populated ROX content)
/etc/exports:
  /srv/nfs/k8s 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
exportfs -rav
```

## On the 3 Kubernetes VMs

```text
swap off
kernel modules overlay, br_netfilter + ip_forward sysctls
containerd (SystemdCgroup = true)
kubeadm, kubelet, kubectl  (v1.35, held)
nfs-common                 (NFS client - kubelet needs it to mount NFS)
mkdir /mnt/disks/rwo       (local RWO disk folder)
```

Log of each VM:

```bash
sudo cat /var/log/lab-setup.log
cloud-init status
```

Expected:

```text
status: done
```

---

# 9. Understand `/etc/exports`

```text
/srv/nfs/k8s 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
```

| Part | Meaning |
|---|---|
| `/srv/nfs/k8s` | exported directory (and everything below it) |
| `10.0.1.0/24` | clients allowed — the whole lab subnet (node IPs, **not** pod IPs) |
| `rw` | read/write at the NFS level |
| `sync` | write to disk before replying |
| `no_subtree_check` | faster, avoids subtree errors |
| `no_root_squash` | root in a container stays root on the share (lab convenience) |

> **Important for the ROX demo:** the export itself is `rw`. Read-only behaviour in
> Kubernetes must come from Kubernetes (`readOnly: true`) — section 22 proves this.

---

# 10. Verify NFS From the Cluster Nodes

SSH to the NFS VM:

```bash
ssh azureuser@<nfs-vm-public-ip>
sudo exportfs -v
sudo ss -lntp | grep 2049
ls -l /srv/nfs/k8s /srv/nfs/k8s/rox
```

Expected:

```text
/srv/nfs/k8s   10.0.1.0/24(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash)
LISTEN 0  64  0.0.0.0:2049 ...
drwxr-xr-x  rox
drwxrwxrwx  rwo
drwxrwxrwx  rwop
drwxrwxrwx  rwx
```

From **each worker** (VM-3 and VM-4):

```bash
showmount -e 10.0.1.4
```

Expected:

```text
Export list for 10.0.1.4:
/srv/nfs/k8s 10.0.1.0/24
```

Manual mount test on `k8s-worker-1`:

```bash
sudo mkdir -p /mnt/nfs-test
sudo mount -t nfs -o nfsvers=4.1 10.0.1.4:/srv/nfs/k8s /mnt/nfs-test
echo "Hello from worker-1" | sudo tee /mnt/nfs-test/rwx/hello.txt
sudo umount /mnt/nfs-test
```

On `k8s-worker-2`:

```bash
sudo mkdir -p /mnt/nfs-test
sudo mount -t nfs -o nfsvers=4.1 10.0.1.4:/srv/nfs/k8s /mnt/nfs-test
cat /mnt/nfs-test/rwx/hello.txt
sudo rm /mnt/nfs-test/rwx/hello.txt
sudo umount /mnt/nfs-test
```

Expected:

```text
Hello from worker-1
```

If this fails, fix NFS/networking first (section 30) — Kubernetes cannot do better than a manual mount.

---

# 11. Copy the Lab Files to the Control Plane

From your laptop (lab folder):

```powershell
scp -r . azureuser@<control-plane-public-ip>:~/k8s-am-lab
```

---

# 12. Initialize the Control Plane

SSH to VM-2:

```bash
ssh azureuser@<control-plane-public-ip>
cd ~/k8s-am-lab
sudo bash scripts/01-init-control-plane.sh
```

The script runs:

```text
kubeadm init --apiserver-advertise-address=10.0.1.5 --pod-network-cidr=192.168.0.0/16
copy admin.conf → ~/.kube/config  (azureuser + root)
Calico v3.31.7 with IPIP=Never, VXLAN=Always   (Azure drops IP-in-IP traffic)
kubeadm token create --print-join-command
```

Expected last lines:

```text
============================================================
 Control plane ready. Run THIS with sudo on k8s-worker-1
 and k8s-worker-2:
============================================================
sudo kubeadm join 10.0.1.5:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:....
============================================================
```

> Why `192.168.0.0/16` for pods? It must **not** overlap the Azure VNet `10.0.0.0/16`.

---

# 13. Join the Workers

SSH to **VM-3** and run the printed command:

```bash
sudo kubeadm join 10.0.1.5:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

Repeat on **VM-4**.

Lost the command? On the control plane:

```bash
sudo cat /root/worker_join.sh
```

---

# 14. Verify the Cluster

On the control plane:

```bash
kubectl get nodes -o wide
```

Expected (after ~1 minute):

```text
NAME                STATUS   ROLES           VERSION   INTERNAL-IP
k8s-control-plane   Ready    control-plane   v1.35.x   10.0.1.5
k8s-worker-1        Ready    <none>          v1.35.x   10.0.1.6
k8s-worker-2        Ready    <none>          v1.35.x   10.0.1.7
```

```bash
kubectl get pods -n kube-system
```

All `calico-*`, `coredns-*`, `kube-*` pods should be `Running`.

Check the taint that keeps demo pods off the control plane:

```bash
kubectl describe node k8s-control-plane | grep Taints
```

```text
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
```

---

# 15. Install the NFS CSI Driver (for RWOP)

```bash
bash scripts/02-install-nfs-csi-driver.sh
```

Expected:

```text
NAME             ATTACHREQUIRED   PODINFOONMOUNT   ...
nfs.csi.k8s.io   false            false            ...
NFS CSI driver ready.
```

Why only for RWOP?

```text
RWO / ROX / RWX demos  → built-in "nfs:" and "local:" volume types (no driver needed)
RWOP demo              → ReadWriteOncePod works ONLY with CSI volumes
```

---

# 16. Prepare the Demo Namespace

```bash
cd ~/k8s-am-lab
kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=access-modes
```

Handy command — **which node is each pod on?**

```bash
kubectl get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
```

---

# 17. Five Rules to Know Before the Demos

```text
1. Access modes are about NODES, not pods.            (except RWOP)
2. On a PVC the mode is a REQUEST, on a PV a CAPABILITY. They must match to bind.
3. Enforcement depends on the storage:
      local disk / Azure Disk → enforced (node affinity / attach)
      NFS / shared FS         → RWO NOT enforced across nodes
      RWOP                    → enforced by scheduler + kubelet
4. ROX does NOT make a mount read-only. readOnly: true does.
5. RWOP must be the only mode on the PV/PVC and needs a CSI driver.
```

Every demo below proves one or more of these rules.

---

# PART A — ReadWriteOnce (RWO)

# 18. RWO With a Real Node-Local Disk

We use a **local PersistentVolume**: a folder on `k8s-worker-1`'s disk. It behaves like
Azure Disk — the data physically exists on one node only.

```text
manifests/01-rwo/rwo-local-pv-pvc.yaml
```

```yaml
kind: StorageClass
metadata:
  name: local-static
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
kind: PersistentVolume
metadata:
  name: rwo-local-pv
spec:
  accessModes:
    - ReadWriteOnce
  local:
    path: /mnt/disks/rwo
  nodeAffinity:                      # the volume lives on worker-1
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k8s-worker-1
---
kind: PersistentVolumeClaim
metadata:
  name: rwo-local-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-static
```

Apply:

```bash
kubectl apply -f manifests/01-rwo/rwo-local-pv-pvc.yaml
kubectl get pv rwo-local-pv
kubectl get pvc rwo-local-pvc
```

Expected:

```text
NAME           CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      STORAGECLASS
rwo-local-pv   1Gi        RWO            Retain           Available   local-static

NAME            STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
rwo-local-pvc   Pending                                      local-static
```

`Pending` is **correct** here:

```bash
kubectl describe pvc rwo-local-pvc | tail -3
```

```text
Normal  WaitForFirstConsumer  waiting for first consumer to be created before binding
```

---

# 19. Three Pods, One Node, One RWO Volume

```bash
kubectl apply -f manifests/01-rwo/rwo-deployment.yaml
kubectl rollout status deploy/rwo-writer
kubectl get pods -l app=rwo-writer -o wide
```

Expected — **all three on `k8s-worker-1`**:

```text
NAME                          READY   STATUS    NODE
rwo-writer-6d9c8b7f4-2xk9p    1/1     Running   k8s-worker-1
rwo-writer-6d9c8b7f4-8qfzt    1/1     Running   k8s-worker-1
rwo-writer-6d9c8b7f4-vj2lm    1/1     Running   k8s-worker-1
```

The scheduler had no choice — the PV's `nodeAffinity` says "worker-1 only".

PVC is now bound:

```bash
kubectl get pvc rwo-local-pvc
```

```text
rwo-local-pvc   Bound    rwo-local-pv   1Gi   RWO   local-static
```

All three pods write to the **same file**:

```bash
kubectl exec deploy/rwo-writer -- tail -6 /data/log.txt
```

```text
10:15:01 pod=rwo-writer-...-2xk9p node=k8s-worker-1
10:15:02 pod=rwo-writer-...-8qfzt node=k8s-worker-1
10:15:02 pod=rwo-writer-...-vj2lm node=k8s-worker-1
```

Prove where the data is — SSH to **k8s-worker-1**:

```bash
tail -3 /mnt/disks/rwo/log.txt
```

And on **k8s-worker-2**:

```bash
ls /mnt/disks/rwo
```

```text
(empty — the data is NOT on worker-2)
```

```text
            k8s-worker-1                       k8s-worker-2
   ┌─────────────────────────────┐      ┌──────────────────────┐
   │ pod-1   pod-2   pod-3       │      │                      │
   │   \       |      /          │      │   (no access)        │
   │    /mnt/disks/rwo  (RW)     │      │                      │
   └─────────────────────────────┘      └──────────────────────┘
```

✅ **RWO = one node. Many pods on that node are fine.**

---

# 20. Try to Use the RWO Volume From Worker 2

```text
manifests/01-rwo/rwo-intruder-pod.yaml
```

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: k8s-worker-2     # force the OTHER node
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: rwo-local-pvc
```

Apply:

```bash
kubectl apply -f manifests/01-rwo/rwo-intruder-pod.yaml
kubectl get pod rwo-intruder
```

```text
NAME           READY   STATUS    RESTARTS   AGE
rwo-intruder   0/1     Pending   0          20s
```

Why?

```bash
kubectl describe pod rwo-intruder | grep -A3 Events
```

```text
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node(s) didn't match Pod's node affinity/selector,
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  1 node(s) had volume node affinity conflict.
```

Read it as:

```text
k8s-worker-1       → not the node the pod asked for
k8s-control-plane  → tainted
k8s-worker-2       → "volume node affinity conflict" = the RWO volume is not here
```

> On Azure Disk / AWS EBS the same situation shows as
> `Multi-Attach error for volume ... Volume is already used by pod(s) ...`.

✅ **A second NODE cannot use a single-node RWO volume.**

Clean up the intruder:

```bash
kubectl delete pod rwo-intruder
```

---

# 21. The RWO Gotcha — RWO on NFS

Now the same experiment with an **NFS** PV marked `ReadWriteOnce`.

```text
manifests/01-rwo/rwo-nfs-pv-pvc.yaml     → PV rwo-nfs-pv (RWO) on 10.0.1.4:/srv/nfs/k8s/rwo
manifests/01-rwo/rwo-nfs-two-nodes.yaml  → pod on worker-1  +  pod on worker-2
```

```bash
kubectl apply -f manifests/01-rwo/rwo-nfs-pv-pvc.yaml
kubectl get pvc rwo-nfs-pvc

kubectl apply -f manifests/01-rwo/rwo-nfs-two-nodes.yaml
kubectl get pods -l '!app' -o wide
```

Expected — **both Running, on different nodes**:

```text
NAME              READY   STATUS    NODE
rwo-nfs-worker1   1/1     Running   k8s-worker-1
rwo-nfs-worker2   1/1     Running   k8s-worker-2
```

```bash
kubectl exec rwo-nfs-worker1 -- tail -4 /data/log.txt
```

```text
10:20:01 from k8s-worker-1
10:20:02 from k8s-worker-2      ← two NODES writing to an "RWO" volume!
10:20:06 from k8s-worker-1
10:20:07 from k8s-worker-2
```

On `nfs-vm`:

```bash
tail -4 /srv/nfs/k8s/rwo/log.txt
```

Why did this work?

```text
Local disk / Azure Disk:  must be ATTACHED to a node  → only one node possible
NFS:                      no attach step, no node affinity → nothing stops node 2
```

⚠️ **Access mode is a CONTRACT, not a LOCK.** If you need a single writer on shared
storage, use **RWOP** (Part D) — not RWO.

Clean up Part A:

```bash
kubectl delete -f manifests/01-rwo/rwo-nfs-two-nodes.yaml
kubectl delete -f manifests/01-rwo/rwo-deployment.yaml
```

---

# PART B — ReadOnlyMany (ROX)

# 22. Publish Pre-Populated Content as ROX

cloud-init already placed a website on the NFS server:

```bash
# on nfs-vm
cat /srv/nfs/k8s/rox/index.html
```

We publish it with **static provisioning**:

```text
manifests/02-rox/rox-pv-pvc.yaml
```

```yaml
kind: PersistentVolume
metadata:
  name: rox-pv
spec:
  accessModes:
    - ReadOnlyMany
  nfs:
    server: 10.0.1.4
    path: /srv/nfs/k8s/rox
---
kind: PersistentVolumeClaim
metadata:
  name: rox-pvc
spec:
  accessModes:
    - ReadOnlyMany
  volumeName: rox-pv
```

Apply:

```bash
kubectl apply -f manifests/02-rox/rox-pv-pvc.yaml
kubectl get pv rox-pv
kubectl get pvc rox-pvc
```

Expected:

```text
NAME     CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
rox-pv   1Gi        ROX            Retain           Bound    access-modes/rox-pvc
```

---

# 23. Four Readers on Two Nodes

```text
manifests/02-rox/rox-nginx.yaml
```

The key lines:

```yaml
      volumes:
        - name: site
          persistentVolumeClaim:
            claimName: rox-pvc
            readOnly: true        # ← THIS makes the mount read-only
```

Apply:

```bash
kubectl apply -f manifests/02-rox/rox-nginx.yaml
kubectl rollout status deploy/rox-web
kubectl get pods -l app=rox-web -o wide
```

Expected — **spread over both workers**:

```text
rox-web-...-a   Running   k8s-worker-1
rox-web-...-b   Running   k8s-worker-1
rox-web-...-c   Running   k8s-worker-2
rox-web-...-d   Running   k8s-worker-2
```

Read the website through the Service:

```bash
kubectl run curl --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- http://rox-web
```

```html
<h1>Hello from a ReadOnlyMany volume</h1>
```

Try to change it:

```bash
kubectl exec deploy/rox-web -- sh -c 'echo hacked > /usr/share/nginx/html/index.html'
```

```text
sh: 1: cannot create /usr/share/nginx/html/index.html: Read-only file system
```

Check the mount flags:

```bash
kubectl exec deploy/rox-web -- sh -c 'mount | grep nginx/html'
```

```text
10.0.1.4:/srv/nfs/k8s/rox on /usr/share/nginx/html type nfs4 (ro,relatime,vers=4.1,...)
                                                              ^^
```

```text
     k8s-worker-1              k8s-worker-2
   ┌───────────────┐        ┌───────────────┐
   │ nginx  nginx  │        │ nginx  nginx  │
   └──────┬────────┘        └───────┬───────┘
          │ ro                      │ ro
          └──────────┬──────────────┘
                     v
           nfs-vm:/srv/nfs/k8s/rox
```

✅ **ROX = many nodes, one dataset, nobody changes it.**

---

# 24. The ROX Gotcha — Forgetting `readOnly: true`

```text
manifests/02-rox/rox-careless-pod.yaml   (same rox-pvc, NO readOnly: true)
```

```bash
kubectl apply -f manifests/02-rox/rox-careless-pod.yaml
kubectl wait --for=condition=Ready pod/rox-careless
kubectl exec rox-careless -- sh -c 'echo oops > /site/oops.txt && ls -l /site'
```

Expected:

```text
-rw-r--r--  1 nobody nogroup ...  about.txt
-rw-r--r--  1 nobody nogroup ...  index.html
-rw-r--r--  1 root   root      5  oops.txt     ← write SUCCEEDED on a "ReadOnlyMany" volume
```

Why?

```text
ReadOnlyMany on PV/PVC  → used only for BINDING (matching)
readOnly: true on pod   → actually mounts "ro"
NFS export is rw        → so nothing else stops the write
```

### Fix — enforce read-only on the PV itself

```text
manifests/02-rox/rox-pv-pvc-enforced.yaml
```

```yaml
  nfs:
    server: 10.0.1.4
    path: /srv/nfs/k8s/rox
    readOnly: true          # ← every pod gets ro, whatever it asks for
```

A PV's volume source cannot be edited in place, so recreate it:

```bash
kubectl exec rox-careless -- rm /site/oops.txt
kubectl delete pod rox-careless
kubectl delete deploy rox-web
kubectl delete pvc rox-pvc
kubectl delete pv rox-pv

kubectl apply -f manifests/02-rox/rox-pv-pvc-enforced.yaml
kubectl apply -f manifests/02-rox/rox-careless-pod.yaml
kubectl wait --for=condition=Ready pod/rox-careless
kubectl exec rox-careless -- sh -c 'echo oops > /site/oops.txt'
```

Expected now:

```text
sh: can't create /site/oops.txt: Read-only file system
```

Three ways to guarantee read-only, weakest → strongest:

```text
1. readOnly: true in every pod            (each app team must remember)
2. nfs.readOnly: true on the PV           (admin enforces for every pod)
3. export the directory "ro" on nfs-vm    (storage itself refuses writes)
```

Clean up Part B:

```bash
kubectl delete pod rox-careless
kubectl delete svc rox-web --ignore-not-found
```

---

# PART C — ReadWriteMany (RWX)

# 25. Many Writers on Many Nodes

```text
manifests/03-rwx/rwx-pv-pvc.yaml     → PV rwx-pv (RWX) on 10.0.1.4:/srv/nfs/k8s/rwx
manifests/03-rwx/rwx-deployment.yaml → 4 writers, spread over both workers
```

```bash
kubectl apply -f manifests/03-rwx/rwx-pv-pvc.yaml
kubectl get pvc rwx-pvc
```

```text
NAME      STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
rwx-pvc   Bound    rwx-pv   1Gi        RWX            nfs-static
```

```bash
kubectl apply -f manifests/03-rwx/rwx-deployment.yaml
kubectl rollout status deploy/rwx-writer
kubectl get pods -l app=rwx-writer -o wide
```

Expected:

```text
rwx-writer-...-p1   Running   k8s-worker-1
rwx-writer-...-p2   Running   k8s-worker-1
rwx-writer-...-p3   Running   k8s-worker-2
rwx-writer-...-p4   Running   k8s-worker-2
```

---

# 26. Prove the File Is Shared

Read from **any** pod — writes from **both** nodes appear:

```bash
kubectl exec deploy/rwx-writer -- tail -8 /shared/events.log
```

```text
10:31:01 pod=rwx-writer-...-p1 node=k8s-worker-1
10:31:01 pod=rwx-writer-...-p3 node=k8s-worker-2
10:31:02 pod=rwx-writer-...-p2 node=k8s-worker-1
10:31:02 pod=rwx-writer-...-p4 node=k8s-worker-2
```

Count lines per node:

```bash
kubectl exec deploy/rwx-writer -- sh -c "awk '{print \$3}' /shared/events.log | sort | uniq -c"
```

```text
     42 node=k8s-worker-1
     41 node=k8s-worker-2
```

Write from one specific pod, read from a pod on the other node:

```bash
POD_W1=$(kubectl get pod -l app=rwx-writer --field-selector spec.nodeName=k8s-worker-1 -o jsonpath='{.items[0].metadata.name}')
POD_W2=$(kubectl get pod -l app=rwx-writer --field-selector spec.nodeName=k8s-worker-2 -o jsonpath='{.items[0].metadata.name}')

kubectl exec "$POD_W1" -- sh -c 'echo "Shared data written on worker-1" > /shared/note.txt'
kubectl exec "$POD_W2" -- cat /shared/note.txt
```

```text
Shared data written on worker-1
```

On `nfs-vm`:

```bash
ls -l /srv/nfs/k8s/rwx
tail -3 /srv/nfs/k8s/rwx/events.log
```

Scale up — new pods see the data instantly:

```bash
kubectl scale deploy/rwx-writer --replicas=6
kubectl get pods -l app=rwx-writer -o wide
```

```text
     k8s-worker-1              k8s-worker-2
   ┌───────────────┐        ┌───────────────┐
   │ writer writer │        │ writer writer │
   └──────┬────────┘        └───────┬───────┘
          │ rw                      │ rw
          └──────────┬──────────────┘
                     v
           nfs-vm:/srv/nfs/k8s/rwx/events.log
```

✅ **RWX = read/write from many nodes at the same time.**
⚠️ Kubernetes only *allows* sharing — **the application must handle concurrent writes**.
Appending small lines is fine; two processes editing one SQLite file is not.

Clean up Part C:

```bash
kubectl delete -f manifests/03-rwx/rwx-deployment.yaml
```

---

# PART D — ReadWriteOncePod (RWOP)

# 27. A Single-Owner Volume

```text
manifests/04-rwop/rwop-pv-pvc.yaml
```

```yaml
kind: PersistentVolume
metadata:
  name: rwop-pv
spec:
  accessModes:
    - ReadWriteOncePod          # must be the only mode
  csi:                          # CSI volume, not "nfs:" — RWOP requires CSI
    driver: nfs.csi.k8s.io
    volumeHandle: lab-rwop-volume
    volumeAttributes:
      server: 10.0.1.4
      share: /srv/nfs/k8s/rwop
```

This is the **same NFS server** as before. Only the way Kubernetes talks to it changed
(through the CSI driver from section 15).

```bash
kubectl apply -f manifests/04-rwop/rwop-pv-pvc.yaml
kubectl get pvc rwop-pvc
```

```text
NAME       STATUS   VOLUME    CAPACITY   ACCESS MODES   STORAGECLASS
rwop-pvc   Bound    rwop-pv   1Gi        RWOP           nfs-csi-static
```

---

# 28. First Owner

```text
manifests/04-rwop/rwop-pod-1.yaml   → nodeSelector: k8s-worker-1
```

```bash
kubectl apply -f manifests/04-rwop/rwop-pod-1.yaml
kubectl wait --for=condition=Ready pod/rwop-pod-1
kubectl get pod rwop-pod-1 -o wide
kubectl exec rwop-pod-1 -- tail -2 /data/owner.log
```

```text
rwop-pod-1   1/1   Running   k8s-worker-1
10:40:05 rwop-pod-1 on k8s-worker-1 owns the volume
```

---

# 29. Second Pod — Same Node → Blocked

```text
manifests/04-rwop/rwop-pod-2.yaml   → nodeSelector: k8s-worker-1   (SAME node as pod-1)
```

Remember section 19: with **RWO**, three pods on the same node worked.

```bash
kubectl apply -f manifests/04-rwop/rwop-pod-2.yaml
kubectl get pod rwop-pod-2
kubectl describe pod rwop-pod-2 | grep -A4 Events
```

Expected:

```text
rwop-pod-2   0/1   Pending

Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node has pod using PersistentVolumeClaim with the same name and ReadWriteOncePod access mode,
  ...
```

Third pod — other node, also blocked:

```bash
kubectl apply -f manifests/04-rwop/rwop-pod-3.yaml
kubectl get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase | grep rwop
```

```text
rwop-pod-1   k8s-worker-1   Running
rwop-pod-2   <none>         Pending
rwop-pod-3   <none>         Pending
```

```text
              k8s-worker-1                         k8s-worker-2
   ┌──────────────────────────────┐        ┌─────────────────────┐
   │ rwop-pod-1 ✓    rwop-pod-2 ✗ │        │   rwop-pod-3 ✗      │
   └──────┬───────────────────────┘        └─────────────────────┘
          │ rw (only one pod in the whole cluster)
          v
   nfs-vm:/srv/nfs/k8s/rwop
```

Compare with section 21: the backend is NFS — where RWO was **not** enforced — but RWOP **is**,
because the scheduler and kubelet enforce it, not the storage.

---

# 30. Hand-Over — Release the Volume

Delete the owner:

```bash
kubectl delete pod rwop-pod-1
kubectl get pods -w | grep rwop        # Ctrl-C after a few seconds
```

Expected: **exactly one** of the waiting pods starts — the other stays Pending:

```text
rwop-pod-2   0/1   ContainerCreating
rwop-pod-2   1/1   Running
rwop-pod-3   0/1   Pending
```

(It may be `rwop-pod-3` that wins — either way, only one.)

The data survived the hand-over:

```bash
kubectl exec rwop-pod-2 -- tail -3 /data/owner.log 2>/dev/null || kubectl exec rwop-pod-3 -- tail -3 /data/owner.log
```

```text
10:41:10 rwop-pod-1 on k8s-worker-1 owns the volume
10:41:15 rwop-pod-1 on k8s-worker-1 owns the volume
10:41:24 rwop-pod-2 on k8s-worker-1 owns the volume
```

✅ **RWOP = exactly one pod in the whole cluster.**

When to use it:

```text
- single-writer apps that corrupt data with two writers (SQLite, Prometheus TSDB, embedded DBs)
- shared storage (NFS / CephFS) where RWO would NOT protect you
- Deployments: use  strategy: Recreate  — a RollingUpdate would wait forever
  for the old pod to release the volume
```

Clean up Part D:

```bash
kubectl delete pod rwop-pod-2 rwop-pod-3 --ignore-not-found
```

---

# PART E — How Binding Uses Access Modes

# 31. PVC ↔ PV Mismatch

A PV that only offers **RWO**, and a PVC asking for **RWX**:

```bash
kubectl apply -f manifests/05-binding/mismatch-pv.yaml
kubectl apply -f manifests/05-binding/mismatch-pvc-rwx.yaml
kubectl get pv binding-demo-pv
kubectl get pvc binding-demo-pvc
```

Expected:

```text
binding-demo-pv    1Gi   RWO   Retain   Available   binding-demo
binding-demo-pvc   Pending                          binding-demo
```

```bash
kubectl describe pvc binding-demo-pvc | grep -A3 Events
```

```text
Normal  FailedBinding  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

Ask for what the PV offers:

```bash
kubectl delete pvc binding-demo-pvc
kubectl apply -f manifests/05-binding/mismatch-pvc-rwo.yaml
kubectl get pvc binding-demo-pvc
```

```text
binding-demo-pvc   Bound   binding-demo-pv   1Gi   RWO   binding-demo
```

```text
PVC requests ⊆ PV offers   →  Bound
PVC requests ⊄ PV offers   →  Pending forever
```

✅ **Access mode is first of all a matching rule between PVC and PV.**

---

# 32. Side-by-Side Results

| Scenario | RWO local | RWO NFS | ROX NFS | RWX NFS | RWOP NFS-CSI |
|---|---|---|---|---|---|
| 2+ pods, **same** node | ✅ §19 | ✅ | ✅ | ✅ | ❌ §29 |
| 2+ pods, **different** nodes | ❌ §20 | ⚠️ ✅ not enforced §21 | ✅ §23 | ✅ §26 | ❌ §29 |
| Pods can write | ✅ | ✅ | only if `readOnly` forgotten ⚠️ §24 | ✅ | ✅ (one pod) |
| Enforced by | PV node affinity | nothing | `readOnly` flag | — | scheduler + kubelet |

---

# 33. Which Mode Should I Use?

```text
Does more than one pod need the data?
├── No ──► Must a 2nd pod be IMPOSSIBLE?
│          ├── Yes ─► RWOP   (CSI driver required)
│          └── No  ─► RWO    (default; one disk per StatefulSet replica)
└── Yes ─► Do they need to write?
           ├── No  ─► ROX    + readOnly: true   (static sites, ML models, shared config)
           └── Yes ─► RWX    (NFS / CephFS / Azure Files / EFS)
```

On Azure specifically:

```text
Azure Disk   → RWO (and RWOP via CSI)     — no RWX for filesystems
Azure Files  → RWX / ROX (SMB or NFS)
```

---

# 34. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `pod has unbound immediate PersistentVolumeClaims` | PVC has no matching PV | `kubectl describe pvc`; check accessModes, storageClassName, volumeName |
| PVC `Pending`, `WaitForFirstConsumer` | normal for `local-static` | create the pod |
| `volume node affinity conflict` | pod asked for a node where the local PV isn't | expected in §20 |
| `mount.nfs: access denied by server` | client IP not in `10.0.1.0/24` | fix `/etc/exports`, `sudo exportfs -rav` |
| `bad option ... need a /sbin/mount.nfs helper` | `nfs-common` missing on worker | `sudo apt install -y nfs-common` |
| Pod stuck `ContainerCreating` on NFS | TCP 2049 blocked / NFS down | `nc -zv 10.0.1.4 2049` from the worker |
| RWOP PV `driver not found` | CSI driver not installed | `bash scripts/02-install-nfs-csi-driver.sh` |
| 2 of 4 replicas `Pending`, `didn't match pod topology spread constraints` | spread counts the tainted control plane as a 3rd node with 0 pods | `nodeTaintsPolicy: Honor` in the constraint (already in the manifests) |
| Nodes `NotReady` | Calico not running | `kubectl -n kube-system get pods -l k8s-app=calico-node` |
| Pods can't reach each other across nodes | Calico not in VXLAN mode | `kubectl get ippools -o yaml` → `vxlanMode: Always` |
| cloud-init didn't finish | apt or network issue | `sudo cat /var/log/lab-setup.log` |

Useful commands:

```bash
kubectl get pv,pvc
kubectl describe pvc <name>
kubectl describe pod <name>
kubectl get events --sort-by=.lastTimestamp | tail -20
sudo exportfs -v          # on nfs-vm
mount | grep nfs          # on a worker
```

---

# 35. Cleanup

## Kubernetes objects

```bash
bash scripts/99-cleanup-demos.sh
```

The data stays (Retain policy):

```bash
# nfs-vm
ls /srv/nfs/k8s/*
# k8s-worker-1
ls /mnt/disks/rwo
```

## Whole Azure lab

On your laptop:

```powershell
.\delete-lab.ps1
```

or:

```powershell
az group delete --name rg-k8s-access-modes --yes --no-wait
```

> Don't forget this step — 4 running VMs cost money every hour.
> To pause instead: `az vm deallocate -g rg-k8s-access-modes -n <vm>` for each VM.

---

# 36. Complete Demo Command Flow

```bash
# ---------- laptop ----------
.\create-lab-vms.ps1
scp -r . azureuser@<cp-public-ip>:~/k8s-am-lab

# ---------- control plane ----------
cd ~/k8s-am-lab
sudo bash scripts/01-init-control-plane.sh
# ---------- each worker ----------
sudo kubeadm join 10.0.1.5:6443 --token ... --discovery-token-ca-cert-hash sha256:...
# ---------- control plane ----------
kubectl get nodes
bash scripts/02-install-nfs-csi-driver.sh
kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=access-modes

# RWO
kubectl apply -f manifests/01-rwo/rwo-local-pv-pvc.yaml
kubectl apply -f manifests/01-rwo/rwo-deployment.yaml        # 3 pods, worker-1
kubectl apply -f manifests/01-rwo/rwo-intruder-pod.yaml      # Pending on worker-2
kubectl apply -f manifests/01-rwo/rwo-nfs-pv-pvc.yaml
kubectl apply -f manifests/01-rwo/rwo-nfs-two-nodes.yaml     # gotcha: both Running

# ROX
kubectl apply -f manifests/02-rox/rox-pv-pvc.yaml
kubectl apply -f manifests/02-rox/rox-nginx.yaml             # writes fail
kubectl apply -f manifests/02-rox/rox-careless-pod.yaml      # gotcha: write works

# RWX
kubectl apply -f manifests/03-rwx/rwx-pv-pvc.yaml
kubectl apply -f manifests/03-rwx/rwx-deployment.yaml        # both nodes write

# RWOP
kubectl apply -f manifests/04-rwop/rwop-pv-pvc.yaml
kubectl apply -f manifests/04-rwop/rwop-pod-1.yaml           # Running
kubectl apply -f manifests/04-rwop/rwop-pod-2.yaml           # Pending (same node!)
kubectl apply -f manifests/04-rwop/rwop-pod-3.yaml           # Pending
kubectl delete pod rwop-pod-1                                # one of them takes over

# Binding
kubectl apply -f manifests/05-binding/mismatch-pv.yaml
kubectl apply -f manifests/05-binding/mismatch-pvc-rwx.yaml  # Pending

# ---------- laptop ----------
.\delete-lab.ps1
```

---

# 37. Final Mental Model

```text
                  ACCESS MODE = "WHO may mount this volume, and how?"

   RWO   ───►  ONE NODE        (any number of pods on it)      read + write
   ROX   ───►  MANY NODES                                      read only*
   RWX   ───►  MANY NODES                                      read + write
   RWOP  ───►  ONE POD         (in the whole cluster)          read + write

   * only if readOnly: true (pod) or readOnly on the PV / export
```

```text
Who enforces it?

   PVC ↔ PV binding         → ALL modes        (mismatch = Pending)
   Storage attach / affinity → RWO on block / local disks only
   Scheduler + kubelet       → RWOP (CSI only)
   readOnly flag             → the real "ro" mount
   Nothing                   → RWO on NFS across nodes  ⚠️
```

---

# 38. Interview Answers

> **"What's the difference between RWO and RWOP?"**

```text
RWO restricts a volume to a single NODE — several pods on that node can still
mount it read-write. RWOP, GA since Kubernetes 1.29, restricts it to a single
POD in the whole cluster, enforced by the scheduler and kubelet. It only works
with CSI volumes. I'd use RWOP for single-writer workloads, especially on
shared storage like NFS where RWO isn't enforced across nodes.
```

> **"Does ReadOnlyMany make my volume read-only?"**

```text
No. The access mode is used to match a PVC to a PV. The mount is read-only only
if the pod sets persistentVolumeClaim.readOnly: true, the PV source sets
readOnly: true, or the storage itself exports the data read-only.
```

> **"How do you share writable storage between pods on different nodes?"**

```text
With a ReadWriteMany volume backed by a shared filesystem — NFS, CephFS, Azure
Files or EFS. Block storage like Azure Disk or EBS can't do RWX for filesystems.
The application still has to handle concurrent writes safely.
```

> **"My PVC is Pending — what do you check?"**

```text
kubectl describe pvc. Then compare the PVC and PV: storageClassName, accessModes
(the PVC's modes must be offered by the PV), capacity and volumeName. For
WaitForFirstConsumer classes, Pending is normal until a pod uses the claim.
```

---

# 39. Versions Used

| Component | Version |
|---|---|
| OS | Ubuntu 22.04 (Azure image `Ubuntu2204`) |
| Kubernetes | v1.35 (kubeadm, pkgs.k8s.io) — `$K8S_MINOR` in `create-lab-vms.ps1` |
| Container runtime | containerd (Ubuntu package) |
| CNI | Calico v3.31.7, VXLAN mode — `CALICO_VERSION` in `01-init-control-plane.sh` |
| NFS CSI driver | v4.13.2 — `CSI_NFS_VERSION` in `02-install-nfs-csi-driver.sh` |

**Core lesson:**

```text
Access mode on PVC / PV
        ↓
decides BINDING
        ↓
storage type decides ENFORCEMENT
        ↓
readOnly decides "ro"
        ↓
RWOP is the only mode Kubernetes itself guarantees for pods
```
