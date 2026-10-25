# Lifecycle of a Volume — hostPath survives a container restart, the rootfs doesn't

A hands-on proof of **what a Kubernetes volume's lifetime actually is**, using a
2-container pod (`nginx` + `sidecar`) that share a **hostPath** volume at
`/shared` (→ `/data/shared` on the node).

We kill the containers with `crictl stop` (the kubelet immediately restarts
them) and watch two kinds of data behave completely differently:

| Where the data lives | Lifetime tied to | `crictl stop` (container restart) | `kubectl delete pod` |
|----------------------|------------------|-----------------------------------|----------------------|
| **`/shared`** (hostPath volume) | the **node** | ✅ **survives** | ✅ survives (data stays in `/data/shared` on the node) |
| container **rootfs** (`/tmp`, `/`, …) | the **container** | ❌ **wiped** (new writable layer) | ❌ wiped |
| `emptyDir` (for contrast) | the **pod** | ✅ survives | ❌ wiped |

> **The point:** a container restart gives the container a brand-new writable
> layer, so anything written *outside* a volume is gone. A **volume** is mounted
> fresh into the new container but points at the *same* backing store, so its
> data persists. That gap is the whole reason volumes exist.

This mirrors the manual experiment where `ungabungacon1` / `ungabungacon2`
(created directly in each container's containerd `rootfs`) disappeared after
`crictl stop`, while `/shared` stayed intact. Here we make it repeatable and
**seed the hostPath before stopping**, then verify.

---

## Files
```
k8s-lifecycle-of-volume/
├── README.md
├── nginx-sidecar.yaml       # the 2-container pod sharing hostPath /shared
└── seed-and-verify.sh       # control-plane helper: seed / before / after
```

## Prerequisites
- A cluster where you can `ssh` to the **node** running the pod and use
  **`crictl`** (kubeadm clusters, killercoda, kind — anything with containerd).
  `crictl stop` is a node-level action; it can't be done from `kubectl`.
- `kubectl` on the control plane.

---

## Step 1 — Deploy the pod
```bash
kubectl apply -f nginx-sidecar.yaml
kubectl get pod nginx-sidecar -o wide
```
Wait for `2/2 Running`:
```
NAME            READY   STATUS    RESTARTS   AGE
nginx-sidecar   2/2     Running   0          20s
```

Confirm `/shared` is a real node-disk mount (not the overlay rootfs):
```bash
kubectl exec nginx-sidecar -c nginx -- df -hT | grep -E 'Filesystem|/shared|overlay'
```
```
Filesystem     Type     Size  Used Avail Use% Mounted on
overlay        overlay   19G  7.1G   12G  39% /            <- container rootfs (ephemeral)
/dev/vda1      ext4      19G  7.1G   12G  39% /shared       <- hostPath volume (node disk)
```
Two different filesystems: `/` is the throwaway overlay, `/shared` is the node's
disk. That difference is what the rest of the demo exploits.

## Step 2 — Seed data BEFORE stopping anything

**(a) into the hostPath VOLUME, from inside the pod:**
```bash
kubectl exec nginx-sidecar -c sidecar -- sh -c 'echo "persist-me @ $(date -u)" > /shared/persist.txt'
kubectl exec nginx-sidecar -c sidecar -- cat /shared/persist.txt
```

**(b) into the hostPath VOLUME, from OUTSIDE (the node) — proves it's the same dir:**
```bash
ssh <node>   # e.g. ssh node01
echo "from-node @ $(date -u)" >> /data/shared/from-node.txt
ls -l /data/shared          # persist.txt + from-node.txt + sidecar.log all here
exit
```

**(c) into the container ROOTFS (ephemeral writable layer) — the control group:**
```bash
kubectl exec nginx-sidecar -c nginx   -- sh -c 'echo "ephemeral nginx"   > /tmp/ephemeral.txt'
kubectl exec nginx-sidecar -c sidecar -- sh -c 'echo "ephemeral sidecar" > /tmp/ephemeral.txt'
```
`/tmp` is part of each container's own writable layer — **not** the volume.

> Shortcut for (a) and (c): `./seed-and-verify.sh seed`

## Step 3 — Snapshot the "before" state
```bash
./seed-and-verify.sh before
# or manually:
kubectl get pod nginx-sidecar                              # RESTARTS 0
kubectl exec nginx-sidecar -c sidecar -- ls -l /shared     # persist.txt, from-node.txt, sidecar.log
kubectl exec nginx-sidecar -c sidecar -- wc -l /shared/sidecar.log   # note the line count
kubectl exec nginx-sidecar -c sidecar -- cat /tmp/ephemeral.txt      # exists now
```

## Step 4 — Kill the containers on the NODE with `crictl stop`
```bash
ssh <node>

# find the two app containers and note their IDs + ATTEMPT (0)
crictl ps | grep nginx-sidecar
# CONTAINER      IMAGE          CREATED       STATE     NAME      ATTEMPT   POD ID   POD
# d4e02f441702e  c6348fa86ba0f  8 min ago     Running   sidecar   0         3ffa...  nginx-sidecar
# b3e8e312b309d  878c33739a8a0  8 min ago     Running   nginx     0         3ffa...  nginx-sidecar

# stop BOTH (use YOUR ids)
crictl stop d4e02f441702e b3e8e312b309d

# look again - the kubelet ALREADY restarted them: new IDs, ATTEMPT = 1
crictl ps | grep nginx-sidecar
# 22e551e98b081  c6348fa86ba0f  Less than a second ago  Running  sidecar  1  3ffa...  nginx-sidecar
# dcc8fbabbe610  878c33739a8a0  1 second ago            Running  nginx    1  3ffa...  nginx-sidecar
exit
```
Key observation: the **POD ID is unchanged** (`3ffa...`) but the **container IDs
changed** and **ATTEMPT went 0 → 1**. The pod sandbox lived; only the containers
were recreated — each with a **fresh writable layer**.

## Step 5 — Verify the lifecycle difference
```bash
./seed-and-verify.sh after
```
or manually:

**✅ Proof A — hostPath volume data SURVIVED:**
```bash
kubectl exec nginx-sidecar -c sidecar -- cat /shared/persist.txt      # still there
kubectl exec nginx-sidecar -c sidecar -- cat /shared/from-node.txt    # still there
```

**✅ Proof B — container rootfs data is GONE:**
```bash
kubectl exec nginx-sidecar -c sidecar -- cat /tmp/ephemeral.txt
# cat: can't open '/tmp/ephemeral.txt': No such file or directory   <- wiped
```
(Exactly like `ungabungacon1`/`ungabungacon2` vanishing in the manual run — those
were made in the container rootfs.)

**✅ Proof C — restart is visible, and the log persisted AND grew:**
```bash
kubectl get pod nginx-sidecar        # RESTARTS is now 2 (both containers), 2/2 Running
kubectl exec nginx-sidecar -c sidecar -- grep STARTED /shared/sidecar.log
# === sidecar container STARTED at ... ===   (first boot)
# === sidecar container STARTED at ... ===   (after crictl stop)  <- proves continuity
kubectl exec nginx-sidecar -c sidecar -- wc -l /shared/sidecar.log   # more lines than in Step 3
```
The `sidecar.log` kept all its old lines *and* got a new "STARTED" marker — the
new container appended to the *same* file on the node.

---

## Optional — contrast with deleting the POD
```bash
kubectl delete pod nginx-sidecar
kubectl apply -f nginx-sidecar.yaml
kubectl exec nginx-sidecar -c sidecar -- cat /shared/persist.txt
```
`persist.txt` is STILL there — because `hostPath` data lives in `/data/shared`
on the node, independent of the pod. Swap the volume for `emptyDir: {}` and rerun:
after `kubectl delete pod` the data is gone (emptyDir is pod-scoped), but it would
still survive a `crictl stop` (container restart). That's the full ladder:

```
container restart (crictl stop)  : rootfs ✗   emptyDir ✓   hostPath ✓
pod delete (kubectl delete pod)  : rootfs ✗   emptyDir ✗   hostPath ✓
```

## Why this happens (one paragraph)
`crictl stop` stops a **container**, not the **pod**. The kubelet sees the
container missing, and per `restartPolicy: Always` it starts a **new** container
in the *same* pod sandbox. A new container = a new copy-on-write **writable
layer**, so every byte written outside a mounted volume is discarded. Volumes are
different: the kubelet re-runs the mount, attaching the *same* backing storage
(here the node directory `/data/shared`) into the new container. The volume's
lifetime is defined by its **type** (hostPath → node, emptyDir → pod, PVC → the
PV/CSI backend), never by the container. That is the entire idea of a volume.

## Cleanup
```bash
kubectl delete pod nginx-sidecar --ignore-not-found
# hostPath data remains on the node until you remove it:
ssh <node> 'rm -rf /data/shared'
```
