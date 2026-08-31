# Kubernetes NFS + PV + PVC Practical on Azure — 3 VM Architecture

## Complete Hands-On Lab

This practical demonstrates how to configure **NFS shared storage for a 2-node Kubernetes cluster using 3 Azure VMs**.

We will use:

```text
VM-1 → Dedicated NFS Server
VM-2 → Kubernetes Control Plane
VM-3 → Kubernetes Worker
```

This is a cleaner architecture than running the NFS server on a Kubernetes node.

---

# 1. Lab Architecture

```text
                         AZURE VNET
                        10.0.1.0/24
                             |
          +------------------+------------------+
          |                  |                  |
          v                  v                  v
     +---------+        +---------+        +---------+
     |  VM-1   |        |  VM-2   |        |  VM-3   |
     |   NFS   |        |   K8s   |        |   K8s   |
     | Server  |        | Control |        | Worker  |
     |         |        | Plane   |        |         |
     |10.0.1.4 |        |10.0.1.5 |        |10.0.1.6 |
     +----+----+        +----+----+        +----+----+
          |                  |                  |
          |                  +--------+---------+
          |                           |
          |                        K8s API
          |                           |
          +------ TCP 2049 -----------+
                    NFS
                     |
                     v
              /srv/nfs/k8s
                     |
                     v
               PersistentVolume
                     |
                     v
              PersistentVolumeClaim
                     |
                     v
                    Pod
```

---

# 2. VM Roles

| VM | Private IP | Role |
|---|---|---|
| VM-1 | `10.0.1.4` | Dedicated NFS Server |
| VM-2 | `10.0.1.5` | Kubernetes Control Plane |
| VM-3 | `10.0.1.6` | Kubernetes Worker |

> Replace these example IPs with your actual Azure private IPs.

The Kubernetes cluster consists of:

```text
VM-2 + VM-3
```

The storage server is:

```text
VM-1
```

---

# 3. What We Will Demonstrate

By the end of this practical you will demonstrate:

```text
NFS Server
    ↓
NFS Export
    ↓
PersistentVolume
    ↓
PersistentVolumeClaim
    ↓
Pod
    ↓
Write Data
    ↓
Delete Pod
    ↓
Recreate Pod
    ↓
Data Still Exists
    ↓
Run Pod on Another K8s Node
    ↓
Same Data Available
```

We will also demonstrate:

- NFS installation
- Azure NSG configuration
- NFS client installation
- Manual NFS mount
- Static PV
- PVC binding
- RWX
- Pod persistence
- Cross-node shared storage
- PV/PVC troubleshooting
- Cleanup

---

# 4. Prerequisites

You need:

- 3 Azure Linux VMs
- VM-1 reachable from VM-2 and VM-3
- Kubernetes installed on VM-2 and VM-3
- `kubectl`
- VM-2 configured as control plane
- VM-3 joined as worker
- Private networking between all three VMs
- `sudo` access

Verify Kubernetes:

```bash
kubectl get nodes -o wide
```

Expected:

```text
NAME       STATUS   ROLES           INTERNAL-IP
vm-2       Ready    control-plane   10.0.1.5
vm-3       Ready    <none>          10.0.1.6
```

---

# 5. Verify Azure VM IP Addresses

On each VM:

```bash
hostname -I
```

or:

```bash
ip addr
```

We will assume:

```text
NFS VM       = 10.0.1.4
Control Plane = 10.0.1.5
Worker        = 10.0.1.6
```

---

# 6. Azure Network Security Group

NFS uses:

```text
TCP 2049
```

Allow:

```text
Source:
Kubernetes VM private IPs/subnet

Destination:
NFS VM

Protocol:
TCP

Port:
2049

Action:
Allow
```

For example:

```text
10.0.1.0/24 → 10.0.1.4:2049
```

For a production environment, restrict the source to only the required Kubernetes nodes/subnet.

## DO NOT

Do not create:

```text
Internet → TCP 2049 → NFS Server
```

Never expose NFS directly to the public Internet for this lab.

---

# 7. Test Network Connectivity

From VM-2:

```bash
ping 10.0.1.4
```

From VM-3:

```bash
ping 10.0.1.4
```

Test NFS port:

```bash
nc -zv 10.0.1.4 2049
```

The port test may fail until NFS is installed.

---

# 8. Configure VM-1 — NFS Server

SSH into VM-1:

```bash
ssh <user>@<vm1-ip>
```

Install NFS server.

For Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
```

Check:

```bash
sudo systemctl status nfs-kernel-server
```

Enable at boot:

```bash
sudo systemctl enable nfs-kernel-server
```

Start:

```bash
sudo systemctl start nfs-kernel-server
```

Or:

```bash
sudo systemctl enable --now nfs-kernel-server
```

---

# 9. Create NFS Storage Directory

Create:

```bash
sudo mkdir -p /srv/nfs/k8s
```

Check:

```bash
ls -ld /srv/nfs/k8s
```

For this learning lab:

```bash
sudo chmod 777 /srv/nfs/k8s
```

> `777` is intentionally used to avoid UID/GID permission issues during the demonstration. Do not use it blindly in production.

---

# 10. Configure NFS Export

Edit:

```bash
sudo nano /etc/exports
```

Add:

```text
/srv/nfs/k8s 10.0.1.0/24(rw,sync,no_subtree_check)
```

If your Kubernetes subnet is different, replace:

```text
10.0.1.0/24
```

with the correct subnet.

For example:

```text
/srv/nfs/k8s 10.10.0.0/24(rw,sync,no_subtree_check)
```

---

# 11. Understand `/etc/exports`

```text
/srv/nfs/k8s
```

The directory being exported.

```text
10.0.1.0/24
```

The clients allowed to access the export.

```text
rw
```

Read/write.

```text
sync
```

Synchronous writes.

```text
no_subtree_check
```

Disables subtree checking.

---

# 12. Apply the NFS Export

Run:

```bash
sudo exportfs -rav
```

Check:

```bash
sudo exportfs -v
```

You should see:

```text
/srv/nfs/k8s
```

Restart NFS:

```bash
sudo systemctl restart nfs-kernel-server
```

Check:

```bash
sudo systemctl is-active nfs-kernel-server
```

Expected:

```text
active
```

---

# 13. Check TCP 2049

On VM-1:

```bash
sudo ss -lntp | grep 2049
```

You should see NFS listening on:

```text
2049
```

---

# 14. Test From VM-2

SSH to VM-2.

Install NFS client:

```bash
sudo apt update
sudo apt install -y nfs-common
```

Check exports:

```bash
showmount -e 10.0.1.4
```

Expected:

```text
Export list for 10.0.1.4:
/srv/nfs/k8s 10.0.1.0/24
```

---

# 15. Test From VM-3

This step is important because the Kubernetes scheduler can run Pods on VM-3.

SSH to VM-3:

```bash
sudo apt update
sudo apt install -y nfs-common
```

Run:

```bash
showmount -e 10.0.1.4
```

Expected:

```text
Export list for 10.0.1.4:
/srv/nfs/k8s 10.0.1.0/24
```

Both Kubernetes nodes must be able to reach the NFS server.

---

# 16. Manual NFS Mount Test — VM-2

On VM-2:

```bash
sudo mkdir -p /mnt/nfs-test
```

Mount:

```bash
sudo mount -t nfs 10.0.1.4:/srv/nfs/k8s /mnt/nfs-test
```

Check:

```bash
mount | grep nfs
```

or:

```bash
df -h | grep nfs
```

Write:

```bash
echo "Hello from VM-2" | sudo tee /mnt/nfs-test/vm2.txt
```

Read:

```bash
cat /mnt/nfs-test/vm2.txt
```

---

# 17. Verify From VM-1

On NFS server:

```bash
cat /srv/nfs/k8s/vm2.txt
```

Expected:

```text
Hello from VM-2
```

---

# 18. Manual NFS Mount Test — VM-3

On VM-3:

```bash
sudo mkdir -p /mnt/nfs-test
```

Mount:

```bash
sudo mount -t nfs 10.0.1.4:/srv/nfs/k8s /mnt/nfs-test
```

Read:

```bash
cat /mnt/nfs-test/vm2.txt
```

Expected:

```text
Hello from VM-2
```

Write:

```bash
echo "Hello from VM-3" | sudo tee /mnt/nfs-test/vm3.txt
```

---

# 19. Verify Again From VM-1

On VM-1:

```bash
ls -l /srv/nfs/k8s
```

Read:

```bash
cat /srv/nfs/k8s/vm3.txt
```

This proves:

```text
VM-2 ─────┐
          |
          v
       NFS Server
          ^
          |
VM-3 ─────┘
```

Both Kubernetes nodes can access the same storage.

Unmount both manual test mounts:

```bash
sudo umount /mnt/nfs-test
```

---

# 20. Create Kubernetes PV

On the Kubernetes control plane VM-2, create:

```text
nfs-pv.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolume

metadata:
  name: nfs-pv

spec:
  capacity:
    storage: 5Gi

  accessModes:
    - ReadWriteMany

  persistentVolumeReclaimPolicy: Retain

  storageClassName: nfs-static

  mountOptions:
    - nfsvers=4

  nfs:
    server: 10.0.1.4
    path: /srv/nfs/k8s
```

Replace:

```text
10.0.1.4
```

with your NFS VM's actual private IP.

---

# 21. Understand the PV

## Capacity

```yaml
capacity:
  storage: 5Gi
```

Kubernetes advertises the PV as 5Gi.

This does not physically resize the NFS filesystem.

---

## Access Mode

```yaml
accessModes:
  - ReadWriteMany
```

RWX means:

```text
ReadWriteMany
```

Multiple nodes can mount the storage read/write.

This is ideal for demonstrating shared NFS storage.

---

## Reclaim Policy

```yaml
persistentVolumeReclaimPolicy: Retain
```

The underlying data is retained when the PVC is deleted.

---

## Storage Class

```yaml
storageClassName: nfs-static
```

The PVC will use the same value to bind to this PV.

---

## NFS Server

```yaml
nfs:
  server: 10.0.1.4
```

This is VM-1.

---

## NFS Path

```yaml
path: /srv/nfs/k8s
```

This is the exported directory.

---

# 22. Apply the PV

```bash
kubectl apply -f nfs-pv.yaml
```

Check:

```bash
kubectl get pv
```

Expected:

```text
NAME      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      STORAGECLASS
nfs-pv    5Gi        RWX            Retain           Available   nfs-static
```

Detailed:

```bash
kubectl describe pv nfs-pv
```

YAML:

```bash
kubectl get pv nfs-pv -o yaml
```

---

# 23. Create PVC

Create:

```text
nfs-pvc.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim

metadata:
  name: nfs-pvc

spec:
  accessModes:
    - ReadWriteMany

  storageClassName: nfs-static

  resources:
    requests:
      storage: 5Gi
```

Apply:

```bash
kubectl apply -f nfs-pvc.yaml
```

---

# 24. Verify PVC Binding

```bash
kubectl get pvc
```

Expected:

```text
NAME      STATUS   VOLUME   CAPACITY   ACCESS MODES
nfs-pvc   Bound    nfs-pv   5Gi        RWX
```

Check PV:

```bash
kubectl get pv
```

Expected:

```text
nfs-pv   5Gi   RWX   Retain   Bound   ...
```

Detailed:

```bash
kubectl describe pvc nfs-pvc
```

---

# 25. Understand PV ↔ PVC

```text
                NFS Server
                    |
                    v
                  NFS
                    |
                    v
              PersistentVolume
                    |
                  Bound
                    |
                    v
          PersistentVolumeClaim
                    |
                    v
                   Pod
```

PV:

```text
Represents available storage.
```

PVC:

```text
Requests/claims storage.
```

---

# 26. Create Test Pod

Create:

```text
nfs-test-pod.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nfs-test-pod

spec:
  containers:
    - name: nginx
      image: nginx:1.27

      volumeMounts:
        - name: nfs-storage
          mountPath: /usr/share/nginx/html

  volumes:
    - name: nfs-storage
      persistentVolumeClaim:
        claimName: nfs-pvc
```

Apply:

```bash
kubectl apply -f nfs-test-pod.yaml
```

---

# 27. Check Which Node Runs the Pod

```bash
kubectl get pod nfs-test-pod -o wide
```

Example:

```text
NAME            STATUS    NODE
nfs-test-pod    Running   vm-3
```

The Pod may run on VM-2 or VM-3 depending on scheduling.

---

# 28. Verify the NFS Mount

```bash
kubectl exec nfs-test-pod -- df -h
```

You can also:

```bash
kubectl exec nfs-test-pod -- mount | grep nfs
```

---

# 29. Write Data From the Pod

```bash
kubectl exec nfs-test-pod --   sh -c 'echo "Hello from Kubernetes Pod" > /usr/share/nginx/html/index.html'
```

Read:

```bash
kubectl exec nfs-test-pod --   cat /usr/share/nginx/html/index.html
```

Expected:

```text
Hello from Kubernetes Pod
```

---

# 30. Verify Data on NFS VM

SSH to VM-1:

```bash
cat /srv/nfs/k8s/index.html
```

Expected:

```text
Hello from Kubernetes Pod
```

The complete path is:

```text
Pod
 |
 v
PVC
 |
 v
PV
 |
 v
NFS
 |
 v
VM-1:/srv/nfs/k8s/index.html
```

---

# 31. Persistence Demo

Delete the Pod:

```bash
kubectl delete pod nfs-test-pod
```

Verify:

```bash
kubectl get pods
```

The Pod is gone.

Check VM-1:

```bash
cat /srv/nfs/k8s/index.html
```

The data remains.

Recreate:

```bash
kubectl apply -f nfs-test-pod.yaml
```

Check:

```bash
kubectl get pod -o wide
```

Read:

```bash
kubectl exec nfs-test-pod --   cat /usr/share/nginx/html/index.html
```

Expected:

```text
Hello from Kubernetes Pod
```

---

# 32. Cross-Node Demonstration

This is the most important part of the 3-VM lab.

We want to prove:

```text
Pod on VM-2
      |
      v
     NFS
      ^
      |
Pod on VM-3
```

The same data must be visible from both nodes.

---

# 33. Force Pod Onto VM-2

Find the node hostname labels:

```bash
kubectl get nodes   -L kubernetes.io/hostname
```

Check:

```bash
kubectl get nodes
```

Suppose:

```text
vm-2
vm-3
```

Edit the Pod:

```bash
kubectl delete pod nfs-test-pod
```

Update `nfs-test-pod.yaml`:

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: vm-2

  containers:
    - name: nginx
      image: nginx:1.27

      volumeMounts:
        - name: nfs-storage
          mountPath: /usr/share/nginx/html

  volumes:
    - name: nfs-storage
      persistentVolumeClaim:
        claimName: nfs-pvc
```

Apply:

```bash
kubectl apply -f nfs-test-pod.yaml
```

Verify:

```bash
kubectl get pod nfs-test-pod -o wide
```

It should run on:

```text
vm-2
```

Write:

```bash
kubectl exec nfs-test-pod --   sh -c 'echo "Data written from VM-2 Pod" > /usr/share/nginx/html/node.txt'
```

---

# 34. Move Pod to VM-3

Delete:

```bash
kubectl delete pod nfs-test-pod
```

Change:

```yaml
nodeSelector:
  kubernetes.io/hostname: vm-3
```

Apply:

```bash
kubectl apply -f nfs-test-pod.yaml
```

Check:

```bash
kubectl get pod nfs-test-pod -o wide
```

It should now run on:

```text
vm-3
```

Read:

```bash
kubectl exec nfs-test-pod --   cat /usr/share/nginx/html/node.txt
```

Expected:

```text
Data written from VM-2 Pod
```

This is the critical proof that the data is not tied to VM-2.

---

# 35. What Actually Happened?

```text
First:

Pod
 |
 | scheduled on
 v
VM-2
 |
 | NFS mount
 v
VM-1:/srv/nfs/k8s
```

Then:

```text
Pod deleted
```

Then recreated:

```text
Pod
 |
 | scheduled on
 v
VM-3
 |
 | NFS mount
 v
VM-1:/srv/nfs/k8s
```

The data remains because:

```text
Data lives on VM-1
```

not inside the Pod or node filesystem.

---

# 36. Demonstrate RWX With Two Pods

Create:

```text
nfs-rwx-demo.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nfs-rwx-demo

spec:
  replicas: 2

  selector:
    matchLabels:
      app: nfs-rwx-demo

  template:
    metadata:
      labels:
        app: nfs-rwx-demo

    spec:
      containers:
        - name: nginx
          image: nginx:1.27

          volumeMounts:
            - name: shared-storage
              mountPath: /usr/share/nginx/html

      volumes:
        - name: shared-storage
          persistentVolumeClaim:
            claimName: nfs-pvc
```

Apply:

```bash
kubectl apply -f nfs-rwx-demo.yaml
```

Check:

```bash
kubectl get pods -l app=nfs-rwx-demo -o wide
```

You may see:

```text
NAME                           NODE
nfs-rwx-demo-xxxxx             vm-2
nfs-rwx-demo-yyyyy             vm-3
```

---

# 37. Test Shared File

Get Pod names:

```bash
kubectl get pods -l app=nfs-rwx-demo
```

Set:

```bash
POD1=<first-pod-name>
POD2=<second-pod-name>
```

Write from Pod 1:

```bash
kubectl exec "$POD1" --   sh -c 'echo "Shared data from Pod 1" > /usr/share/nginx/html/shared.txt'
```

Read from Pod 2:

```bash
kubectl exec "$POD2" --   cat /usr/share/nginx/html/shared.txt
```

Expected:

```text
Shared data from Pod 1
```

This demonstrates:

```text
Pod 1
  |
  +------+
         |
        NFS
         |
  +------+
  |
Pod 2
```

---

# 38. Why RWX Matters

Without shared storage:

```text
Pod A → Node 1 → local storage

Pod B → Node 2 → different storage
```

With NFS RWX:

```text
Pod A ─────┐
           |
           v
          NFS
           ^
           |
Pod B ─────┘
```

Both Pods can access the same filesystem.

---

# 39. Inspect Everything

## Nodes

```bash
kubectl get nodes -o wide
```

## PV

```bash
kubectl get pv
kubectl describe pv nfs-pv
```

## PVC

```bash
kubectl get pvc
kubectl describe pvc nfs-pvc
```

## Pods

```bash
kubectl get pods -o wide
```

## Deployment

```bash
kubectl get deployment
```

## Events

```bash
kubectl get events --sort-by=.lastTimestamp
```

---

# 40. Inspect PV YAML

```bash
kubectl get pv nfs-pv -o yaml
```

Look for:

```yaml
spec:
  nfs:
    server: 10.0.1.4
    path: /srv/nfs/k8s
```

---

# 41. Inspect PVC YAML

```bash
kubectl get pvc nfs-pvc -o yaml
```

Look for:

```yaml
status:
  phase: Bound
```

and:

```yaml
spec:
  volumeName: nfs-pv
```

---

# 42. Useful JSONPath Commands

PV status:

```bash
kubectl get pv nfs-pv   -o jsonpath='{.status.phase}'
```

PVC status:

```bash
kubectl get pvc nfs-pvc   -o jsonpath='{.status.phase}'
```

PVC bound volume:

```bash
kubectl get pvc nfs-pvc   -o jsonpath='{.spec.volumeName}'
```

Pod node:

```bash
kubectl get pod nfs-test-pod   -o jsonpath='{.spec.nodeName}'
```

---

# 43. Troubleshooting — PVC Pending

Run:

```bash
kubectl get pv
kubectl get pvc
kubectl describe pvc nfs-pvc
```

Check that PV and PVC agree on:

```text
storageClassName
accessModes
capacity
```

PV:

```yaml
storageClassName: nfs-static

accessModes:
  - ReadWriteMany
```

PVC:

```yaml
storageClassName: nfs-static

accessModes:
  - ReadWriteMany
```

---

# 44. Troubleshooting — Pod Mount Failure

Run:

```bash
kubectl describe pod nfs-test-pod
```

Look at Events.

Typical causes:

```text
Wrong NFS server IP
Wrong NFS path
NFS server unavailable
TCP 2049 blocked
Azure NSG
Linux firewall
NFS client missing
/etc/exports incorrect
NFS permissions
```

---

# 45. Troubleshooting — Test NFS Outside Kubernetes

On VM-2:

```bash
showmount -e 10.0.1.4
```

On VM-3:

```bash
showmount -e 10.0.1.4
```

Then:

```bash
sudo mount -t nfs 10.0.1.4:/srv/nfs/k8s /mnt/nfs-test
```

If manual mounting fails, fix NFS/networking first.

---

# 46. Troubleshooting — NFS Server

On VM-1:

```bash
sudo systemctl status nfs-kernel-server
```

Check exports:

```bash
sudo exportfs -v
```

Reload:

```bash
sudo exportfs -rav
```

Check port:

```bash
sudo ss -lntp | grep 2049
```

---

# 47. Troubleshooting — Kubernetes Nodes

On VM-2:

```bash
dpkg -l | grep nfs-common
```

On VM-3:

```bash
dpkg -l | grep nfs-common
```

Install if necessary:

```bash
sudo apt install -y nfs-common
```

Both Kubernetes nodes need the NFS client utilities if they may mount NFS volumes.

---

# 48. Troubleshooting — Azure NSG

If this works:

```bash
ping 10.0.1.4
```

but this fails:

```bash
nc -zv 10.0.1.4 2049
```

check:

```text
Azure NSG
Linux firewall
NFS service
```

The traffic path must be:

```text
VM-2 ───────┐
            |
            | TCP 2049
            v
          VM-1
        NFS Server
            ^
            |
            | TCP 2049
            |
VM-3 ───────┘
```

---

# 49. Persistence Demonstration Summary

The experiment:

```text
1. Pod runs on VM-2
2. Write file
3. Delete Pod
4. Recreate Pod
5. Run Pod on VM-3
6. Read same file
```

Expected result:

```text
File still exists
```

Why?

```text
Pod storage       → temporary lifecycle

NFS storage       → external storage

PV                → Kubernetes storage representation

PVC               → storage claim
```

---

# 50. PVC Deletion and Retain Policy

Delete Deployment:

```bash
kubectl delete -f nfs-rwx-demo.yaml
```

Delete test Pod:

```bash
kubectl delete -f nfs-test-pod.yaml
```

Delete PVC:

```bash
kubectl delete pvc nfs-pvc
```

Check:

```bash
kubectl get pv
```

Because we configured:

```yaml
persistentVolumeReclaimPolicy: Retain
```

the PV can move to:

```text
Released
```

The actual NFS files remain:

```bash
ls -l /srv/nfs/k8s
```

---

# 51. Recreate Cleanly

Delete the old PV object:

```bash
kubectl delete pv nfs-pv
```

Then recreate:

```bash
kubectl apply -f nfs-pv.yaml
kubectl apply -f nfs-pvc.yaml
```

Check:

```bash
kubectl get pv,pvc
```

Expected:

```text
nfs-pv    Bound
nfs-pvc   Bound
```

The NFS data still exists because it is stored outside the Kubernetes PV object.

---

# 52. Final Cleanup

Delete application:

```bash
kubectl delete -f nfs-rwx-demo.yaml
```

Delete test Pod:

```bash
kubectl delete -f nfs-test-pod.yaml
```

Delete PVC:

```bash
kubectl delete -f nfs-pvc.yaml
```

Delete PV:

```bash
kubectl delete -f nfs-pv.yaml
```

Verify:

```bash
kubectl get pv
kubectl get pvc
```

---

# 53. Optional NFS Data Cleanup

On VM-1:

```bash
ls -l /srv/nfs/k8s
```

If this is only a lab and you want to remove the test data:

```bash
sudo rm -rf /srv/nfs/k8s/*
```

Remove the export from:

```bash
sudo nano /etc/exports
```

Then:

```bash
sudo exportfs -rav
```

If you are finished with NFS:

```bash
sudo systemctl disable --now nfs-kernel-server
```

---

# 54. Complete Demo Command Flow

## Step 1 — VM-1

```bash
sudo apt update
sudo apt install -y nfs-kernel-server

sudo mkdir -p /srv/nfs/k8s
sudo chmod 777 /srv/nfs/k8s

sudo nano /etc/exports
```

Add:

```text
/srv/nfs/k8s 10.0.1.0/24(rw,sync,no_subtree_check)
```

Then:

```bash
sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server
sudo ss -lntp | grep 2049
```

---

## Step 2 — VM-2 and VM-3

Run on both:

```bash
sudo apt update
sudo apt install -y nfs-common
```

Test:

```bash
showmount -e 10.0.1.4
```

---

## Step 3 — Kubernetes

```bash
kubectl get nodes -o wide
```

Apply PV:

```bash
kubectl apply -f nfs-pv.yaml
```

Check:

```bash
kubectl get pv
```

Apply PVC:

```bash
kubectl apply -f nfs-pvc.yaml
```

Check:

```bash
kubectl get pvc
kubectl get pv
```

Create Pod:

```bash
kubectl apply -f nfs-test-pod.yaml
```

Check:

```bash
kubectl get pod -o wide
```

Write:

```bash
kubectl exec nfs-test-pod --   sh -c 'echo "Hello from Kubernetes" > /usr/share/nginx/html/index.html'
```

Read:

```bash
kubectl exec nfs-test-pod --   cat /usr/share/nginx/html/index.html
```

Verify on NFS:

```bash
cat /srv/nfs/k8s/index.html
```

Delete Pod:

```bash
kubectl delete pod nfs-test-pod
```

Recreate:

```bash
kubectl apply -f nfs-test-pod.yaml
```

Read again:

```bash
kubectl exec nfs-test-pod --   cat /usr/share/nginx/html/index.html
```

---

# 55. The Most Important Demonstration

Your final teaching/demo sequence should be:

```text
                 VM-1
              NFS Server
             10.0.1.4
                  |
                  |
             TCP 2049
                  |
        +---------+---------+
        |                   |
        v                   v
      VM-2                VM-3
   K8s Control           K8s Worker
        |                   |
        +---------+---------+
                  |
                  v
                 PVC
                  |
                  v
                  PV
                  |
                  v
            NFS Storage
                  |
                  v
          /srv/nfs/k8s
```

Then demonstrate:

```text
Pod on VM-2
    |
    v
write data
    |
    v
NFS VM-1
    |
    v
delete Pod
    |
    v
new Pod on VM-3
    |
    v
read same data
```

That proves:

```text
Persistence
+
Shared storage
+
RWX
+
Multi-node Kubernetes
```

---

# 56. Final Mental Model

Remember these four layers:

```text
                APPLICATION
                     |
                     v
                    POD
                     |
                     v
                    PVC
             "I need storage"
                     |
                     v
                    PV
             "Here is storage"
                     |
                     v
                    NFS
          "Here is the actual data"
                     |
                     v
              NFS VM-1
```

The critical distinction is:

```text
PVC ≠ storage

PV ≠ physical disk

NFS = storage backend

NFS VM = where the actual data lives
```

---

# 57. Interview Answer

If asked:

> "How would you provide shared persistent storage to a 2-node Kubernetes cluster using Azure VMs?"

A good answer is:

```text
I can dedicate one Azure VM as an NFS server and keep
the other two VMs as the Kubernetes control-plane and
worker nodes. The NFS server exports a directory over
TCP 2049. Kubernetes nodes install the NFS client. I then
create a static NFS-backed PersistentVolume with ReadWriteMany,
create a matching PersistentVolumeClaim, and mount the PVC
into Pods. Because the data lives on the NFS server rather
than the Pod or node filesystem, the same data remains
available when a Pod is recreated or scheduled onto another
Kubernetes node.
```

---

# 58. Final Architecture to Remember

```text
Azure
 |
 +---------------------------+
 |                           |
 |     NFS VM                |
 |     VM-1                   |
 |     10.0.1.4               |
 |        |                   |
 |        | TCP 2049          |
 |        |                   |
 +--------+-------------------+
          |
          v
    /srv/nfs/k8s
          |
          v
       NFS PV
          |
          v
       NFS PVC
          |
      +---+---+
      |       |
      v       v
   Pod A    Pod B
      |       |
    VM-2     VM-3
      |       |
      +---+---+
          |
     Same shared
        data
```

**Core lesson:**

```text
Dedicated NFS VM
       ↓
NFS Export
       ↓
PersistentVolume
       ↓
PersistentVolumeClaim
       ↓
Pod
       ↓
Shared persistent data
```
