# OverlayFS, rootfs and /tmp in Kubernetes — Teaching Lab

A hands-on lab that shows **where a container's files actually live**, why writes
inside a container disappear, and how Kubernetes volumes (`emptyDir`, tmpfs) change that.

**Audience:** engineers who know basic `kubectl` and want to understand container storage.
**Duration:** ~90 minutes (5 labs, ~15 min each + discussion).
**Works on:** kind, minikube, k3s or any cluster with containerd/CRI-O (overlayfs snapshotter).

---

## Files

| File | Lab | Teaches |
|---|---|---|
| `01-rootfs-overlay.yaml` | 1 & 2 | rootfs = overlayfs; copy-up and whiteouts |
| `02-restart-persistence.yaml` | 3 | rootfs vs emptyDir across container restarts |
| `03-readonly-rootfs-tmp.yaml` | 4 | read-only rootfs + emptyDir at `/tmp` (best practice) |
| `04-tmpfs-and-limits.yaml` | 5 | `medium: Memory` (tmpfs), memory accounting, ephemeral-storage eviction |

---

## Core concepts (whiteboard first, ~10 min)

```
             Container sees one filesystem "/"
  ┌──────────────────────────────────────────────────┐
  │                  merged  (overlay)                │
  └──────────────────────────────────────────────────┘
        ▲ writes go here            ▲ reads fall through
  ┌───────────────┐          ┌──────────────────────┐
  │   upperdir    │  RW      │ lowerdir (image       │  RO
  │ (container    │          │ layers, shared by all │
  │  layer)       │          │ containers of image)  │
  └───────────────┘          └──────────────────────┘
        + workdir (overlay's internal scratch space)
```

1. **Image layers are read-only** (`lowerdir`). Many containers share them.
2. **Each container gets a thin writable layer** (`upperdir`). Deleted when the *container* is removed — including on a container restart.
3. **Copy-up:** modifying a file from a lower layer copies the whole file to `upperdir` first.
4. **Whiteout:** deleting a lower-layer file creates a special char device (0/0) in `upperdir` that hides it.
5. **`/tmp` is not special.** In a container it is just a directory in the overlay rootfs — unlike many Linux hosts, it is *not* tmpfs unless you make it one.
6. **Volumes bypass the overlay.** An `emptyDir` is a plain directory on the node (`/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~empty-dir/<name>`), or tmpfs with `medium: Memory`. It lives as long as the **Pod**, not the container.
7. **Both count as ephemeral storage.** Writable layer + disk-backed emptyDir + logs count toward `ephemeral-storage` requests/limits; memory-backed emptyDir counts toward **memory**.

| Location | Backed by | Survives container restart | Survives pod deletion | Counted against |
|---|---|---|---|---|
| rootfs (incl. default `/tmp`) | overlay upperdir | ❌ | ❌ | ephemeral-storage |
| `emptyDir` | node disk | ✅ | ❌ | ephemeral-storage |
| `emptyDir medium: Memory` | tmpfs (RAM) | ✅ | ❌ | memory limit |
| PVC | external storage | ✅ | ✅ | PVC size |

---

## Prerequisites

```bash
kubectl version
kubectl get nodes -o wide          # note the container runtime column
kubectl create namespace storage-lab
kubectl config set-context --current --namespace=storage-lab
```

**Node access** (needed for Labs 1–2 "behind the scenes" parts) — pick one:

```bash
# Any cluster (K8s 1.23+)
kubectl debug node/<node-name> -it --image=busybox
chroot /host                        # now you are on the node

# kind
docker exec -it kind-control-plane bash

# minikube
minikube ssh
```

---

## Lab 1 — The rootfs is an overlay mount (15 min)

```bash
kubectl apply -f 01-rootfs-overlay.yaml
kubectl wait --for=condition=Ready pod/overlay-demo
kubectl exec -it overlay-demo -- sh
```

Inside the container:

```sh
mount | grep ' / '
# overlay on / type overlay (rw,relatime,lowerdir=...:...,upperdir=.../fs,workdir=.../work)

df -h /                       # size reported is the NODE's disk, not a per-container quota
cat /proc/self/mountinfo | grep -E ' / | /etc/hosts | /scratch '
```

**Discussion points**
- `lowerdir` has several colon-separated paths → one per image layer.
- `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf` are **bind mounts** from kubelet, not part of the overlay.
- `/scratch` (the emptyDir) is a separate mount — not overlay.

On the **node**, look at the same mount from outside:

```sh
mount | grep overlay | grep -v ' /var/lib/docker' | head
# containerd keeps snapshots under:
ls /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/
```

Find this container's upperdir precisely:

```sh
CID=$(crictl ps --name app -q | head -1)
crictl inspect $CID | grep -i -E 'upperdir|rootfs|snapshotKey' | head
# or copy the upperdir path from the `mount` output inside the container
```

---

## Lab 2 — Copy-up and whiteouts (15 min)

Keep a container shell and a node shell open side-by-side. Set `UPPER` on the node to the
upperdir path from Lab 1.

**In the container:**
```sh
echo "hello from container layer" > /new-file.txt   # new file
echo "# edited" >> /etc/profile                     # modify a lower-layer file -> copy-up
rm /etc/motd 2>/dev/null || rm /bin/vi              # delete a lower-layer file -> whiteout
```

**On the node:**
```sh
ls -la $UPPER                 # new-file.txt appears
ls -la $UPPER/etc             # profile is here now (full copy, not a diff)
ls -la $UPPER/bin $UPPER/etc  # deleted file shows as:  c--------- 0,0  <name>   (whiteout)
```

**Teaching points**
- Copy-up copies the **entire file**. Appending 1 byte to a 2 GB file in a lower layer costs 2 GB of writable space and time.
- Deleting a file from the image does **not** free space — the lower layer still holds it. (Same reason `RUN rm` in a later Dockerfile layer doesn't shrink images.)
- The lower layer on disk is untouched; other containers using the same image still see the original files.

```bash
kubectl delete -f 01-rootfs-overlay.yaml
```

---

## Lab 3 — Container restart: rootfs vs emptyDir (15 min)

```bash
kubectl apply -f 02-restart-persistence.yaml
kubectl wait --for=condition=Ready pod/restart-demo

kubectl exec restart-demo -- sh -c 'echo rootfs  > /rootfs-file.txt'
kubectl exec restart-demo -- sh -c 'echo rootfs-tmp > /tmp/tmp-file.txt'
kubectl exec restart-demo -- sh -c 'echo emptydir > /data/emptydir-file.txt'
```

Ask the class to **predict** which files survive, then crash the container (not the pod):

```bash
kubectl exec restart-demo -- kill 1       # PID 1 traps TERM and exits 1
kubectl get pod restart-demo -w           # RESTARTS goes 0 -> 1, same pod name/UID
```

```bash
kubectl exec restart-demo -- ls -l /rootfs-file.txt /tmp/tmp-file.txt /data/emptydir-file.txt
```

**Expected:** only `/data/emptydir-file.txt` survives. The new container got a **fresh upperdir**;
the emptyDir belongs to the pod.

Now delete the pod and recreate it — the emptyDir is gone too:

```bash
kubectl delete pod restart-demo && kubectl apply -f 02-restart-persistence.yaml
kubectl wait --for=condition=Ready pod/restart-demo
kubectl exec restart-demo -- ls /data           # empty
kubectl delete -f 02-restart-persistence.yaml
```

Bonus (on node): find the emptyDir before deleting the pod:
```sh
ls /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~empty-dir/data
# pod UID: kubectl get pod restart-demo -o jsonpath='{.metadata.uid}'
```

---

## Lab 4 — Read-only rootfs with a writable /tmp (15 min)

The security best practice: make the overlay read-only, mount `emptyDir` only where the app
needs to write.

```bash
kubectl apply -f 03-readonly-rootfs-tmp.yaml
kubectl wait --for=condition=Ready pod/readonly-demo
kubectl exec -it readonly-demo -- sh
```

```sh
touch /etc/hacked          # touch: /etc/hacked: Read-only file system
touch /usr/bin/evil        # Read-only file system
touch /tmp/ok && echo ok   # works — /tmp is an emptyDir
touch /var/cache/app/ok && echo ok
mount | grep -E ' / | /tmp '   # / shows "ro", /tmp is a separate mount
```

**Teaching points**
- Attackers can't drop binaries into the image paths; image stays immutable.
- Common breakage: apps writing to `/tmp`, `/var/run`, `/var/cache`, `~/.cache`, nginx `/var/cache/nginx`. Fix with targeted emptyDirs, not by disabling read-only.
- Combine with `runAsNonRoot`, `allowPrivilegeEscalation: false`, dropped capabilities.

```bash
kubectl delete -f 03-readonly-rootfs-tmp.yaml
```

---

## Lab 5 — tmpfs /tmp and storage limits (20 min)

`04-tmpfs-and-limits.yaml` creates two pods.

### 5a — memory-backed /tmp counts against memory

```bash
kubectl apply -f 04-tmpfs-and-limits.yaml
kubectl wait --for=condition=Ready pod/tmpfs-demo pod/eviction-demo

kubectl exec tmpfs-demo -- mount | grep /tmp        # tmpfs on /tmp
kubectl exec tmpfs-demo -- df -h /tmp               # size capped (sizeLimit / memory limit on recent K8s)

# Write 40Mi — fine (limit 128Mi)
kubectl exec tmpfs-demo -- dd if=/dev/zero of=/tmp/f1 bs=1M count=40
kubectl exec tmpfs-demo -- cat /sys/fs/cgroup/memory.current   # cgroup v2: memory went up ~40Mi

# Try to exceed
kubectl exec tmpfs-demo -- dd if=/dev/zero of=/tmp/f2 bs=1M count=200
kubectl get pod tmpfs-demo -w
```

Depending on version, you'll see either `No space left on device` (tmpfs sized to the limit)
or the container **OOMKilled**. Either way: **RAM-backed /tmp is RAM.** Fast, but size it carefully.

### 5b — ephemeral-storage limit causes eviction

```bash
# Limit is 100Mi. Write 150Mi to the overlay rootfs:
kubectl exec eviction-demo -- dd if=/dev/zero of=/bigfile bs=1M count=150
kubectl get pod eviction-demo -w        # after kubelet's next check (~10-60s): Evicted / Failed
kubectl describe pod eviction-demo | grep -A3 -i -E 'evict|ephemeral'
```

**Teaching points**
- Writes to the **rootfs** and **disk emptyDir** both count against `ephemeral-storage`.
- Eviction is **not** instant — kubelet checks periodically, so the disk can briefly overfill.
- Evicted pods are not restarted in place; a Deployment would schedule a replacement.
- Always set `ephemeral-storage` requests/limits on workloads that write temp files.

```bash
kubectl delete -f 04-tmpfs-and-limits.yaml --ignore-not-found
```

---

## Wrap-up quiz (5 min)

1. A container appends a line to a 500 MB file shipped in the image. How much writable-layer space is used? *(~500 MB — copy-up)*
2. You `rm` a 1 GB file from the image inside a running container. Does node disk usage drop? *(No — whiteout only)*
3. Your app crash-loops and loses its cache each time. Cheapest fix? *(emptyDir for the cache path)*
4. Why might a pod with `memory: 256Mi` get OOMKilled while its process uses 50Mi? *(it wrote ~200Mi to a `medium: Memory` emptyDir)*
5. Is `/tmp` in a container tmpfs by default? *(No — it's part of the overlay rootfs)*

## Cleanup

```bash
kubectl delete namespace storage-lab
kubectl config set-context --current --namespace=default
```

## Troubleshooting

- **`mount` shows no overlay** — your runtime uses a different snapshotter (btrfs, zfs, native) or a VM-based runtime (gVisor, Kata). The concepts hold; the on-disk paths differ.
- **`kubectl debug node` image pull fails** — use any image you already have, or `docker exec`/`minikube ssh`.
- **No `crictl` on node** — use the upperdir path from the in-container `mount` output instead.
- **cgroup v1 nodes** — use `/sys/fs/cgroup/memory/memory.usage_in_bytes` in Lab 5a.
