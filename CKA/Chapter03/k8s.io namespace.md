# k8s-resilience-demo — Build & Load into Kubernetes (`k8s.io`)

This guide shows how to build the Docker image locally and make it available
**directly to your Kubernetes cluster** without pushing to a remote registry, by
importing it into containerd's `k8s.io` namespace.

---

## What is `k8s.io` and why does it matter?

`k8s.io` is a **containerd namespace** — *not* a Kubernetes namespace.

- **Kubernetes namespaces** (`default`, `kube-system`, …) partition *cluster
  resources* like pods and services.
- **containerd namespaces** (`k8s.io`, `default`, `moby`) isolate *containerd's
  own metadata* — images, containers, and snapshots — so several tools can share
  one containerd daemon safely.

| containerd namespace | Used by |
|----------------------|---------|
| `default`            | `ctr`, `nerdctl` (default) |
| `k8s.io`             | Kubernetes (kubelet / CRI plugin) |
| `moby`               | Docker on containerd |

**The key point:** the kubelet only reads images from the `k8s.io` namespace.
If you import an image without `-n k8s.io`, it goes into `default`, and
Kubernetes behaves as if the image doesn't exist — you'll see `ErrImageNeverPull`
or `ImagePullBackOff` even though the image is on the node. The `-n k8s.io` flag
is what makes the image visible to your cluster.

---

## Prerequisites

- Docker installed on your build machine.
- A Kubernetes node whose container runtime is **containerd** (the common case).
- SSH/root access to that node (`ctr` requires `sudo`).

Confirm your runtime:

```bash
kubectl get nodes -o wide          # look at the CONTAINER-RUNTIME column
# e.g. containerd://1.7.x
```

---

## Step 1 — Build the image

```bash
docker build -t your-registry/k8s-resilience-demo:1.0 .
```

> Keep whatever tag you plan to reference in your Deployment. The tag you build
> with is the tag Kubernetes must request later.

---

## Step 2 — Export the image to a tar archive

```bash
docker save your-registry/k8s-resilience-demo:1.0 -o k8s-resilience-demo.tar
```

---

## Step 3 — Copy the tar to the Kubernetes node

Skip this if you built the image on the node itself.

```bash
scp k8s-resilience-demo.tar user@<node-ip>:/tmp/
```

---

## Step 4 — Import into the `k8s.io` namespace

On the node:

```bash
sudo ctr -n k8s.io images import /tmp/k8s-resilience-demo.tar
```

The `-n k8s.io` is essential — it places the image where the kubelet looks.

---

## Step 5 — Verify the image is visible to Kubernetes

```bash
sudo ctr -n k8s.io images list | grep k8s-resilience-demo
```

Expected output (something like):

```
your-registry/k8s-resilience-demo:1.0    application/vnd.oci.image.manifest.v1+json ...
```

You can also confirm through the CRI, which always uses `k8s.io`:

```bash
sudo crictl images | grep k8s-resilience-demo
```

---

## Step 6 — Use the local image in a Deployment

Because the image already lives on the node, tell Kubernetes **not** to pull it
from a registry:

```yaml
containers:
  - name: k8s-resilience-demo
    image: your-registry/k8s-resilience-demo:1.0
    imagePullPolicy: IfNotPresent   # or Never — never pull from a remote registry
```

- `IfNotPresent` — use the local image; only pull if it's missing.
- `Never` — fail rather than ever pull. Useful to guarantee the local image is used.

Apply and check:

```bash
kubectl apply -f deployment.yaml
kubectl get pods -w
```

---

## Multi-node clusters

Each node has its own containerd image store. Repeat **Steps 3–5** on every node
that might schedule the pod, or restrict scheduling to the node that has the
image (e.g. with a `nodeSelector` or node affinity). For anything beyond a
one-node demo, a shared registry is usually simpler.

---

## Quick reference

```bash
# Build
docker build -t your-registry/k8s-resilience-demo:1.0 .

# Export
docker save your-registry/k8s-resilience-demo:1.0 -o k8s-resilience-demo.tar

# Import into the namespace Kubernetes uses
sudo ctr -n k8s.io images import k8s-resilience-demo.tar

# Verify
sudo ctr -n k8s.io images list | grep k8s-resilience-demo
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ErrImageNeverPull` / `ImagePullBackOff` with `Never`/`IfNotPresent` | Image imported into the wrong containerd namespace | Re-import with `-n k8s.io` |
| Image shows in `ctr images list` but not `ctr -n k8s.io images list` | It's in the `default` namespace | Import again with `-n k8s.io` |
| Works on one node, fails on another | Image only present on one node | Import on all candidate nodes, or pin scheduling |
| Kubernetes still tries to pull from a registry | `imagePullPolicy: Always` | Set it to `IfNotPresent` or `Never` |
