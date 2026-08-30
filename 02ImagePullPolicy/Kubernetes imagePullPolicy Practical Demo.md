# Kubernetes `imagePullPolicy` Practical Demo

This practical demonstrates the three Kubernetes `imagePullPolicy` values:

- `Always`
- `IfNotPresent`
- `Never`

It also demonstrates Kubernetes' **default `imagePullPolicy` behavior**, including the special behavior of the `latest` tag.

---

# 1. Objective

The objective of this demo is to practically prove:

```text
imagePullPolicy
       |
       +---- Always
       |
       +---- IfNotPresent
       |
       +---- Never
```

We will verify what happens when:

- The image is already present on the worker node.
- The image is not present on the worker node.
- A Pod is deleted and recreated.
- The image tag is `latest`.
- No `imagePullPolicy` is explicitly specified.

---

# 2. Prerequisites

You need:

- A working Kubernetes cluster.
- `kubectl` configured.
- Access to a Kubernetes worker node.
- `crictl` installed if using containerd.
- Internet access for the image-pull demonstrations.

Check the cluster:

```bash
kubectl get nodes
```

Example:

```text
NAME           STATUS   ROLES           AGE   VERSION
controlplane   Ready    control-plane   10d   v1.30.x
node01         Ready    <none>          10d   v1.30.x
```

---

# 3. Directory Structure

Create a directory:

```bash
mkdir imagepull-demo
cd imagepull-demo
```

The final structure will be:

```text
imagepull-demo/
│
├── always.yaml
├── ifnotpresent.yaml
├── never.yaml
├── never-fail.yaml
├── default.yaml
└── latest.yaml
```

---

# 4. How `imagePullPolicy` Works

Kubernetes supports three values:

```text
Always
IfNotPresent
Never
```

## Always

```text
Pod starts
    |
    v
Check registry
    |
    v
Pull image
    |
    v
Start container
```

The image is pulled whenever the container is started.

---

## IfNotPresent

```text
Pod starts
    |
    v
Is image available locally?
       |
   +---+---+
   |       |
  YES      NO
   |       |
   v       v
Use       Pull
local     image
image       |
   |        |
   +----+---+
        |
        v
 Start container
```

If the image already exists on the node, Kubernetes uses the local image.

If it does not exist, Kubernetes pulls it.

---

## Never

```text
Pod starts
    |
    v
Do NOT pull image
    |
    v
Is image available locally?
       |
   +---+---+
   |       |
  YES      NO
   |       |
   v       v
Start    ERROR
Pod
```

Kubernetes never attempts to pull the image.

---

# 5. Check Images on the Worker Node

SSH into the worker node.

For containerd:

```bash
crictl images
```

Example:

```text
IMAGE                     TAG
docker.io/library/nginx   1.27
```

You can also use:

```bash
ctr -n k8s.io images list
```

> Run `crictl images` on the Kubernetes worker node, not on your laptop.

---

# 6. Demo 1 — `Always`

Create:

```bash
vim always.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-always
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      imagePullPolicy: Always
```

Apply:

```bash
kubectl apply -f always.yaml
```

Check:

```bash
kubectl get pod image-always
```

Expected:

```text
NAME           READY   STATUS    RESTARTS   AGE
image-always   1/1     Running   0          10s
```

---

## Check Events

Run:

```bash
kubectl describe pod image-always
```

Look at the Events section.

You should see events similar to:

```text
Pulling image "nginx:1.27"
Successfully pulled image "nginx:1.27"
Created container nginx
Started container nginx
```

---

# 7. Prove `Always`

Delete the Pod:

```bash
kubectl delete pod image-always
```

Create it again:

```bash
kubectl apply -f always.yaml
```

Check:

```bash
kubectl describe pod image-always
```

Again look for:

```text
Pulling image "nginx:1.27"
```

The important observation is:

```text
First Pod creation
        |
        v
Image pulled
        |
        v
Pod deleted
        |
        v
Pod recreated
        |
        v
Image pulled again
```

Therefore:

```text
imagePullPolicy: Always
```

means:

```text
Pull the image whenever the container starts.
```

---

# 8. Demo 2 — `IfNotPresent`

Create:

```bash
vim ifnotpresent.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-ifnotpresent
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      imagePullPolicy: IfNotPresent
```

Apply:

```bash
kubectl apply -f ifnotpresent.yaml
```

Check:

```bash
kubectl get pod image-ifnotpresent
```

---

# 9. First Start of `IfNotPresent`

If the image does not already exist on the worker node, Kubernetes pulls it.

Check:

```bash
kubectl describe pod image-ifnotpresent
```

You may see:

```text
Pulling image "nginx:1.27"
Successfully pulled image "nginx:1.27"
```

Now the image exists locally on the worker node.

Verify:

```bash
crictl images | grep nginx
```

---

# 10. Prove `IfNotPresent`

Delete the Pod:

```bash
kubectl delete pod image-ifnotpresent
```

Create it again:

```bash
kubectl apply -f ifnotpresent.yaml
```

Check:

```bash
kubectl describe pod image-ifnotpresent
```

The existing local image can be reused.

Representation:

```text
First start
    |
    v
Image absent
    |
    v
PULL
    |
    v
Image stored locally


Second start
    |
    v
Image present locally
    |
    v
DO NOT PULL
    |
    v
Use local image
```

Therefore:

```text
imagePullPolicy: IfNotPresent
```

means:

```text
Pull only if the image is not already present locally.
```

---

# 11. Demo 3 — `Never`

Create:

```bash
vim never.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-never
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      imagePullPolicy: Never
```

Before creating the Pod, make sure the image exists on the worker node:

```bash
crictl images | grep nginx
```

Then:

```bash
kubectl apply -f never.yaml
```

Check:

```bash
kubectl get pod image-never
```

Expected:

```text
NAME          READY   STATUS    RESTARTS   AGE
image-never   1/1     Running   0          10s
```

Because the image already exists locally, the container can start.

---

# 12. Prove `Never` With a Missing Image

Create:

```bash
vim never-fail.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-never-fail
spec:
  containers:
    - name: nginx
      image: nginx:does-not-exist
      imagePullPolicy: Never
```

Apply:

```bash
kubectl apply -f never-fail.yaml
```

Check:

```bash
kubectl get pod image-never-fail
```

Expected status:

```text
NAME               READY   STATUS
image-never-fail   0/1     ErrImageNeverPull
```

Now:

```bash
kubectl describe pod image-never-fail
```

The important observation is that Kubernetes does **not** attempt to download the image.

Representation:

```text
nginx:does-not-exist
        |
        v
imagePullPolicy: Never
        |
        v
DO NOT CONTACT REGISTRY
        |
        v
Image exists locally?
        |
       NO
        |
        v
ErrImageNeverPull
```

---

# 13. Demo 4 — Default `imagePullPolicy`

Now let's see what Kubernetes does when we do not specify:

```yaml
imagePullPolicy:
```

Create:

```bash
vim default.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-default
spec:
  containers:
    - name: nginx
      image: nginx:1.27
```

Notice:

```yaml
imagePullPolicy
```

is missing.

Apply:

```bash
kubectl apply -f default.yaml
```

Now inspect the Pod:

```bash
kubectl get pod image-default -o yaml
```

Search for:

```yaml
imagePullPolicy:
```

For a normal non-`latest` tag such as:

```text
nginx:1.27
```

the default is generally:

```yaml
imagePullPolicy: IfNotPresent
```

---

# 14. Demo 5 — `latest` Tag

Create:

```bash
vim latest.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-latest
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

Notice that we have not specified:

```yaml
imagePullPolicy
```

Create the Pod:

```bash
kubectl apply -f latest.yaml
```

Check:

```bash
kubectl get pod image-latest -o yaml
```

Look for:

```yaml
imagePullPolicy: Always
```

So:

```text
image: nginx:latest
        |
        v
No imagePullPolicy
        |
        v
Default
        |
        v
Always
```

---

# 15. Default Policy Rules

The important rules are:

| Image specification | `imagePullPolicy` not specified | Default |
|---|---|---|
| `nginx:latest` | Yes | `Always` |
| `nginx` | Yes | `Always` |
| `nginx:1.27` | Yes | `IfNotPresent` |
| `nginx:v1` | Yes | `IfNotPresent` |
| `nginx:2.0` | Yes | `IfNotPresent` |

So remember:

```text
latest
  |
  v
Always
```

and:

```text
Specific version tag
  |
  v
IfNotPresent
```

---

# 16. Complete Comparison

| Policy | Image Exists Locally | Pull? | Result |
|---|---:|---:|---|
| `Always` | Yes | Yes | Container starts |
| `Always` | No | Yes | Container starts if pull succeeds |
| `IfNotPresent` | Yes | No | Container starts |
| `IfNotPresent` | No | Yes | Container starts if pull succeeds |
| `Never` | Yes | No | Container starts |
| `Never` | No | No | `ErrImageNeverPull` |

---

# 17. Practical Proof Using Events

The easiest way to demonstrate the behavior during a class is:

```bash
kubectl describe pod <pod-name>
```

Look at:

```text
Events:
```

For example:

```text
Pulling image "nginx:1.27"
Successfully pulled image "nginx:1.27"
```

This proves that Kubernetes attempted to pull the image.

For `IfNotPresent`, once the image exists locally, recreating the Pod can reuse the local image.

For `Never`, a missing image produces:

```text
ErrImageNeverPull
```

---

# 18. Check the Local Image

On the worker node:

```bash
crictl images
```

Filter nginx:

```bash
crictl images | grep nginx
```

You can also use:

```bash
ctr -n k8s.io images list | grep nginx
```

This is useful for proving the difference between:

```text
Image exists on node
```

and:

```text
Image must be downloaded
```

---

# 19. Complete Demo Flow

Run the following in order.

## Step 1 — Check images

On worker node:

```bash
crictl images
```

---

## Step 2 — Always

On the machine where `kubectl` is configured:

```bash
kubectl apply -f always.yaml
kubectl describe pod image-always
```

Delete:

```bash
kubectl delete pod image-always
```

Create again:

```bash
kubectl apply -f always.yaml
kubectl describe pod image-always
```

Observe the image pull.

---

## Step 3 — IfNotPresent

```bash
kubectl apply -f ifnotpresent.yaml
kubectl describe pod image-ifnotpresent
```

Delete:

```bash
kubectl delete pod image-ifnotpresent
```

Create again:

```bash
kubectl apply -f ifnotpresent.yaml
kubectl describe pod image-ifnotpresent
```

Observe that the existing local image can be reused.

---

## Step 4 — Never

Make sure the image exists:

```bash
crictl images | grep nginx
```

Then:

```bash
kubectl apply -f never.yaml
kubectl get pod image-never
```

---

## Step 5 — Prove Never Failure

```bash
kubectl apply -f never-fail.yaml
```

Check:

```bash
kubectl get pod image-never-fail
```

Expected:

```text
ErrImageNeverPull
```

---

## Step 6 — Default

```bash
kubectl apply -f default.yaml
kubectl get pod image-default -o yaml
```

Find:

```yaml
imagePullPolicy: IfNotPresent
```

---

## Step 7 — latest

```bash
kubectl apply -f latest.yaml
kubectl get pod image-latest -o yaml
```

Find:

```yaml
imagePullPolicy: Always
```

---

# 20. Useful Commands

List all Pods:

```bash
kubectl get pods
```

Detailed Pod information:

```bash
kubectl describe pod <pod-name>
```

Show complete Pod YAML:

```bash
kubectl get pod <pod-name> -o yaml
```

Show image information:

```bash
kubectl get pod <pod-name> \
  -o jsonpath='{.spec.containers[*].image}'
```

Show image pull policy:

```bash
kubectl get pod <pod-name> \
  -o jsonpath='{.spec.containers[*].imagePullPolicy}'
```

Example:

```bash
kubectl get pod image-latest \
  -o jsonpath='{.spec.containers[*].imagePullPolicy}'
```

Expected:

```text
Always
```

---

# 21. Cleanup

Delete all demo Pods:

```bash
kubectl delete pod image-always
kubectl delete pod image-ifnotpresent
kubectl delete pod image-never
kubectl delete pod image-never-fail
kubectl delete pod image-default
kubectl delete pod image-latest
```

Or:

```bash
kubectl delete -f .
```

---

# 22. Classroom Diagram

Use this representation while teaching:

```text
                 Kubernetes Pod
                       |
                       v
                imagePullPolicy
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
      Always      IfNotPresent       Never
        |              |              |
        v              v              v
   Always Pull     Is image        Never Pull
                   available?
                      |
                 +----+----+
                 |         |
                YES        NO
                 |         |
                 v         v
              Use Local   Pull
                            |
                            v
                         Registry
```

---

# 23. One-Line Memory Trick

```text
Always
→ Always pull

IfNotPresent
→ Pull if image is absent

Never
→ Never pull
```

---

# 24. Interview Questions

### Q1. What does `Always` mean?

The container runtime attempts to resolve/pull the image whenever the container is started.

---

### Q2. What does `IfNotPresent` mean?

The image is pulled only when it is not already available locally on the node.

---

### Q3. What does `Never` mean?

Kubernetes does not pull the image. The image must already exist locally.

---

### Q4. What happens if `Never` is used but the image does not exist?

The Pod cannot start and you will see an image-pull-related failure such as:

```text
ErrImageNeverPull
```

---

### Q5. What is the default policy for `nginx:latest`?

```text
Always
```

---

### Q6. What is the typical default for `nginx:1.27`?

```text
IfNotPresent
```

---

### Q7. Does `IfNotPresent` always mean Kubernetes never contacts the registry?

No.

If the image is absent locally, Kubernetes can contact the registry and pull it.

---

### Q8. Where is the image actually stored?

The image is stored in the container runtime's local image store on the worker node.

For a containerd-based cluster, you can inspect it using:

```bash
crictl images
```

or:

```bash
ctr -n k8s.io images list
```

---

# 25. Final Takeaway

```text
                    imagePullPolicy
                          |
          +---------------+---------------+
          |               |               |
          v               v               v
       Always       IfNotPresent        Never
          |               |               |
          v               v               v
      Pull image      Pull only if     Never pull
      on start       image absent
                          |
                          v
                     Local image
```

The most important practical distinction is:

```text
Always
    → Registry check/pull behavior on every container start

IfNotPresent
    → Reuse local image when available

Never
    → Local image only
```

And the key default rule:

```text
latest tag
    → Always

specific version tag
    → IfNotPresent
```

This demo should be run on a real Kubernetes worker node with `crictl images` available so students can observe both the **Kubernetes Pod events** and the **local container-runtime image store**.