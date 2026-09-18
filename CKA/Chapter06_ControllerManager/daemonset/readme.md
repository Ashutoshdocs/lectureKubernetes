# Kubernetes DaemonSet — Node-Wide Pods, Scheduling & Rollouts

A hands-on guide to running a **DaemonSet** (one Pod per node), controlling which nodes
it targets with **labels**, **nodeSelectors**, **cordon**, and **taints**, and
performing rolling updates and rollbacks.

---

## Table of Contents

1. [Overview](#overview)
2. [Key Concepts](#key-concepts)
3. [DaemonSet vs. Deployment vs. ReplicaSet](#daemonset-vs-deployment-vs-replicaset)
4. [The Manifests](#the-manifests)
5. [Step-by-Step Workflow](#step-by-step-workflow)
6. [Node Scheduling: Labels, Cordon & Taints](#node-scheduling-labels-cordon--taints)
7. [How a DaemonSet Schedules Pods](#how-a-daemonset-schedules-pods)
8. [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet)
9. [Troubleshooting Tips](#troubleshooting-tips)

---

## Overview

A **DaemonSet** ensures that **one copy of a Pod runs on every node** (or on every
node that matches a set of rules). As nodes join the cluster, the DaemonSet
automatically adds a Pod to them; as nodes leave, their Pods are removed.

```
DaemonSet ──▶ 1 Pod on node-1
          ──▶ 1 Pod on node-2
          ──▶ 1 Pod on node-3  (auto-added when node joins)
```

DaemonSets are ideal for **per-node agents**: log collectors, monitoring agents,
storage daemons, and network plugins.

---

## Key Concepts

| Term | What it does |
|------|--------------|
| **DaemonSet** | Runs exactly one Pod per (matching) node, cluster-wide. |
| **nodeSelector** | Restricts the DaemonSet to nodes carrying specific labels. |
| **Label** | A key/value tag on a node or Pod used for selection. |
| **Cordon** | Marks a node unschedulable for *new* workloads (existing Pods stay). |
| **Taint** | Repels Pods from a node unless they have a matching toleration. |
| **Toleration** | Lets a Pod be scheduled onto a node with a matching taint. |
| **Rollout** | The controlled update of DaemonSet Pods to a new template. |

---

## DaemonSet vs. Deployment vs. ReplicaSet

| Behavior | DaemonSet | Deployment / ReplicaSet |
|----------|-----------|--------------------------|
| Pod count | **One per node** (auto-scales with nodes) | Fixed number of replicas you set |
| New node joins | Pod added automatically | No change |
| Typical use | Per-node agents (logging, monitoring) | Stateless apps / services |
| Rolling updates | ✅ Yes | ✅ Yes (Deployment) |

> **Key idea:** You never set `replicas` on a DaemonSet. The node count *is* the
> replica count.

---

## The Manifests

### 1. Basic DaemonSet (`daemonset.yml`)

Runs an `nginx` Pod on **every** node in the cluster.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-daemonset
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx           # must match the selector above
    spec:
      containers:
      - name: nginx
        image: nginx
```

### 2. Targeted DaemonSet with `nodeSelector`

Runs a `monitor` Pod **only on nodes labeled `role=worker`**.

```yaml
# Label the nodes first, then apply this manifest:
#   kubectl label node worker1 role=worker
#   kubectl label node worker2 role=worker
# Verify:
#   kubectl get nodes --show-labels

apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: monitoring-agent
spec:
  selector:
    matchLabels:
      app: monitor
  template:
    metadata:
      labels:
        app: monitor         # must match the selector above
    spec:
      nodeSelector:
        role: worker         # only schedule on nodes with label role=worker
      containers:
      - name: monitor
        image: nginx
```

> **Critical rule:** In both manifests, `template.metadata.labels` **must** match
> `spec.selector.matchLabels`, or Kubernetes rejects the manifest.

---

## Step-by-Step Workflow

### Create and verify

```bash
# Create the DaemonSet
kubectl apply -f daemonset.yml

# Verify it exists
kubectl get daemonset

# See full details and events
kubectl describe daemonset nginx-daemonset

# Check which node each Pod landed on
kubectl get pods -o wide

# List all nodes in the cluster
kubectl get nodes
```

`kubectl get daemonset` shows **DESIRED**, **CURRENT**, **READY**, and **UP-TO-DATE**
counts — these should equal the number of eligible nodes.

### Auto-scaling with the cluster

```bash
# After a new node joins, the DaemonSet adds a Pod automatically
kubectl get daemonset
kubectl get pods -o wide
```

**Expected:** the Pod count grows to match the new node count — no manual action
needed.

### Self-healing

```bash
# Delete one DaemonSet Pod
kubectl delete pod <daemonset-pod-name>

# The DaemonSet recreates it automatically
kubectl get pods -o wide

# Inspect events/status
kubectl describe daemonset nginx-daemonset
```

**Expected:** a new Pod appears on the same node within seconds.

### Rolling update & rollback

```bash
# Update the container image
kubectl set image daemonset/nginx-daemonset nginx=nginx:alpine

# Watch the rollout progress
kubectl rollout status daemonset/nginx-daemonset

# View revision history
kubectl rollout history daemonset/nginx-daemonset

# Roll back to the previous version if needed
kubectl rollout undo daemonset/nginx-daemonset

# Confirm the running image
kubectl describe daemonset nginx-daemonset
```

Unlike a plain ReplicaSet, a DaemonSet **does** perform rolling updates — Pods are
replaced node-by-node using the default `RollingUpdate` strategy.

### Delete

```bash
kubectl delete daemonset nginx-daemonset

# Verify removal
kubectl get daemonset
kubectl get pods
```

---

## Node Scheduling: Labels, Cordon & Taints

### Labels — tag nodes for targeting

```bash
kubectl label node worker1 role=worker
kubectl label node worker2 role=worker

# Verify
kubectl get nodes --show-labels
```

Labels are what a `nodeSelector` (like in the monitoring manifest) matches against.

### Cordon — stop scheduling new Pods

```bash
# Mark the node unschedulable
kubectl cordon worker1

# Confirm status (shows SchedulingDisabled)
kubectl get nodes
```

**Important DaemonSet behavior:** a DaemonSet **ignores cordon**. If you delete its
Pod on a cordoned node, the DaemonSet **still recreates it**:

```bash
kubectl delete pod <daemonset-pod-name>
kubectl get pods -o wide   # Pod comes back even on the cordoned node
```

This is by design — per-node agents (like monitoring) must keep running even when a
node is drained of regular workloads.

```bash
# Re-enable scheduling
kubectl uncordon worker1
```

### Taints — repel Pods from a node

```bash
# Add a taint (NoSchedule = don't place Pods here without a matching toleration)
kubectl taint node worker1 env=prod:NoSchedule

# Verify
kubectl describe node worker1   # look under "Taints:"

# Remove the taint (note the trailing minus sign)
kubectl taint node worker1 env-
```

> **Cordon vs. Taint:**
> - **Cordon** blocks new *regular* scheduling but DaemonSet Pods still run.
> - **Taint** repels Pods entirely unless they carry a matching **toleration**.

---

## How a DaemonSet Schedules Pods

```
─────────────────────────────────────────────────────────────
 PLAIN DAEMONSET (no nodeSelector)
─────────────────────────────────────────────────────────────
   node-1 ✅   node-2 ✅   node-3 ✅      → 1 Pod on every node

   node-4 joins the cluster:
   node-1 ✅   node-2 ✅   node-3 ✅   node-4 ✅   → Pod auto-added

─────────────────────────────────────────────────────────────
 DAEMONSET WITH nodeSelector: role=worker
─────────────────────────────────────────────────────────────
   worker1 (role=worker) ✅
   worker2 (role=worker) ✅
   master  (no label)    ⛔  → skipped, no Pod placed
─────────────────────────────────────────────────────────────
```

---

## Quick Reference Cheat Sheet

```bash
# Lifecycle
kubectl apply -f daemonset.yml
kubectl get daemonset
kubectl describe daemonset nginx-daemonset
kubectl get pods -o wide
kubectl delete daemonset nginx-daemonset

# Updates
kubectl set image daemonset/nginx-daemonset nginx=nginx:alpine
kubectl rollout status  daemonset/nginx-daemonset
kubectl rollout history daemonset/nginx-daemonset
kubectl rollout undo    daemonset/nginx-daemonset

# Node labels
kubectl label node worker1 role=worker
kubectl get nodes --show-labels

# Cordon / uncordon
kubectl cordon   worker1
kubectl uncordon worker1

# Taints
kubectl taint node worker1 env=prod:NoSchedule   # add
kubectl taint node worker1 env-                   # remove
```

---

## Troubleshooting Tips

- **No Pods created** — with a `nodeSelector`, ensure the nodes are actually labeled
  (`kubectl get nodes --show-labels`). No matching nodes = no Pods.
- **Pod won't schedule on a node** — the node may have a **taint**. Check
  `kubectl describe node <node>` under `Taints:`, and add a matching toleration or
  remove the taint.
- **DaemonSet Pod reappears after deletion on a cordoned node** — expected behavior;
  DaemonSets bypass cordon by design.
- **Rollout stuck** — a new Pod may be failing readiness. Run
  `kubectl describe daemonset nginx-daemonset` and check the events.
- **`ImagePullBackOff` after update** — verify the new tag exists (e.g.,
  `nginx:alpine`).
- **Taint not removed** — remember the trailing minus: `kubectl taint node worker1 env-`
  (removes the `env` taint).

---

*Generated as a reference for the `nginx-daemonset` and `monitoring-agent` DaemonSet practical.*
