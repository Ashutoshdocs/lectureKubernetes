# Demo: Autohealing in Kubernetes

This demo shows how a Kubernetes **Deployment** self-heals. A Deployment's
ReplicaSet controller constantly reconciles *desired state* (replicas) against
*actual state*. If a Pod disappears, the controller recreates it — and the
scheduler places the replacement on whatever node is currently **schedulable**.

By flipping node **taints** between the control plane and a worker, and then
deleting the Pod, you can watch Kubernetes rebuild the Pod and reschedule it
onto a different node automatically.

---

## What this demonstrates

- A `Deployment` keeps the desired number of Pods alive (autohealing).
- Node **taints** with the `NoSchedule` effect control *where new Pods land*.
- Deleting a Pod triggers the ReplicaSet to create a fresh one, which the
  scheduler moves to the only untainted node.

> **Key nuance:** `NoSchedule` only affects **new** scheduling decisions. It
> does **not** evict a Pod that is already running. That's why Step 6 deletes
> the Pod manually — the delete is what forces a reschedule.

---

## Prerequisites

- A working Kubernetes cluster (e.g. `controlplane` + `node01`).
- `kubectl` configured and able to reach the cluster.
- `containerd` (or another CRI runtime) running on the nodes.
- Root / `sudo` access on the node where you install `crictl`.

Confirm your cluster is reachable:

```bash
kubectl get nodes -o wide
```

---

## Step 1 — Install `crictl`

`crictl` is the CLI for CRI-compatible container runtimes. Match the version to
your Kubernetes minor version where possible.

```bash
# Pick a version that matches your cluster (example uses v1.30.0)
VERSION="v1.30.0"

wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-amd64.tar.gz
```

Point `crictl` at your runtime socket (containerd shown here):

```bash
sudo tee /etc/crictl.yaml >/dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

Verify:

```bash
crictl version
crictl ps          # list running containers on this node
```

---

## Step 2 — Remove taints from all nodes

Start from a clean slate so every node is schedulable. The default control-plane
taint uses the key `node-role.kubernetes.io/control-plane`. The trailing `-`
**removes** the taint.

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

Confirm no `NoSchedule` taints remain:

```bash
kubectl describe nodes | grep -i taint
# Expected: "Taints: <none>" on each node
```

---

## Step 3 — Taint the control plane

Make `controlplane` unschedulable for regular Pods.

```bash
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule
```

Verify:

```bash
kubectl describe node controlplane | grep -i taint
# Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

---

## Step 4 — Create a Deployment (1 Pod)

Because `controlplane` is tainted, the single Pod should land on **node01**.

```bash
kubectl create deployment web --image=nginx --replicas=1
```

Check placement:

```bash
kubectl get pods -o wide
# The pod should be Running on node01
```

---

## Step 5 — Untaint control plane, taint node01

Now flip the taints: make `controlplane` schedulable again and block `node01`.

```bash
# Untaint the control plane
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane-

# Taint node01 with a custom key
kubectl taint nodes node01 demo=autoheal:NoSchedule
```

Verify the taints have swapped:

```bash
kubectl describe node controlplane | grep -i taint   # -> <none>
kubectl describe node node01      | grep -i taint   # -> demo=autoheal:NoSchedule
```

> The existing Pod is **still running on node01** at this point — `NoSchedule`
> does not evict running Pods. Confirm with `kubectl get pods -o wide`.

---

## Step 6 — Delete the Pod and watch it self-heal

Delete the Pod. The ReplicaSet recreates it, and since `node01` is now tainted,
the scheduler places the new Pod on `controlplane`.

```bash
# Grab the pod name and delete it
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD"

# Watch the replacement come up
kubectl get pods -o wide -w
```

Expected result: a **new** Pod is created (autohealing) and it is scheduled onto
**controlplane**, the only untainted node.

---

## Cleanup

Restore the cluster to its original state.

```bash
# Remove the demo deployment
kubectl delete deployment web

# Remove the node01 taint
kubectl taint nodes node01 demo=autoheal:NoSchedule-

# (Optional) Restore the default control-plane taint
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule
```

---

## Quick reference

| Action                 | Command pattern                                          |
|------------------------|---------------------------------------------------------|
| Add taint              | `kubectl taint nodes <node> <key>=<value>:NoSchedule`   |
| Remove taint           | `kubectl taint nodes <node> <key>-`                      |
| Remove taint (all)     | `kubectl taint nodes --all <key>-`                       |
| View taints            | `kubectl describe node <node> \| grep -i taint`         |
| Pod placement          | `kubectl get pods -o wide`                               |

## Taint effects at a glance

| Effect             | New Pods            | Running Pods                     |
|--------------------|---------------------|----------------------------------|
| `NoSchedule`       | Blocked             | Left alone (not evicted)         |
| `PreferNoSchedule` | Avoided if possible | Left alone                       |
| `NoExecute`        | Blocked             | Evicted (unless they tolerate it)|
