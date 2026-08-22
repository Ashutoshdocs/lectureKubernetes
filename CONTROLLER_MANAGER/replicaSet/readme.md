# Kubernetes ReplicaSet — Create, Edit & Update Pods

A hands-on guide to creating a **ReplicaSet**, inspecting the Pods it manages, editing
its configuration, and understanding why a ReplicaSet (unlike a Deployment) needs its
Pods deleted manually to pick up an image change.

---

## Table of Contents

1. [Overview](#overview)
2. [Key Concepts](#key-concepts)
3. [ReplicaSet vs. Deployment](#replicaset-vs-deployment)
4. [The ReplicaSet Manifest (`replicaset.yaml`)](#the-replicaset-manifest-replicasetyaml)
5. [Step-by-Step Workflow](#step-by-step-workflow)
6. [Why You Must Delete Pods to Update the Image](#why-you-must-delete-pods-to-update-the-image)
7. [How the ReplicaSet Keeps Pods Alive](#how-the-replicaset-keeps-pods-alive)
8. [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet)
9. [Troubleshooting Tips](#troubleshooting-tips)

---

## Overview

A **ReplicaSet** is a Kubernetes controller whose one job is to keep a specified
number of identical Pods running at all times. If a Pod dies, is deleted, or the node
fails, the ReplicaSet automatically creates a replacement.

```
ReplicaSet ──▶ Pods (kept at the desired replica count)
```

In practice you usually use a **Deployment** (which manages ReplicaSets for you), but
working directly with a ReplicaSet is the best way to understand what happens
underneath.

---

## Key Concepts

| Term | What it does |
|------|--------------|
| **ReplicaSet** | Ensures a fixed number of identical Pod replicas are running. |
| **Replica** | A single running copy of a Pod. `replicas: 3` means three copies. |
| **Selector** | The labels the ReplicaSet uses to identify which Pods it owns. |
| **Pod template** | The blueprint used to create new Pods when replicas are missing. |
| **Label** | A key/value tag on a Pod; the selector matches against these. |
| **Reconciliation** | The controller's continuous loop that keeps actual state = desired state. |

---

## ReplicaSet vs. Deployment

This is the single most important thing to understand before running the steps:

| Behavior | ReplicaSet | Deployment |
|----------|-----------|------------|
| Keeps N replicas running | ✅ Yes | ✅ Yes |
| Rolling updates on image change | ❌ No | ✅ Yes |
| Auto-replaces Pods after `edit` | ❌ **No** — existing Pods keep the old image | ✅ Yes |
| Rollback history / revisions | ❌ No | ✅ Yes |

> **Takeaway:** Editing a ReplicaSet's image does **not** restart existing Pods. Only
> *new* Pods use the new image, so you must delete the old Pods manually (Step 7) to
> force the change. A Deployment would handle this automatically.

---

## The ReplicaSet Manifest (`replicaset.yaml`)

```yaml
# The API version used for ReplicaSet resources.
apiVersion: apps/v1

# The resource type being defined — in this case, a ReplicaSet.
kind: ReplicaSet

# Metadata contains identifying information for the ReplicaSet.
metadata:
  name: nginx-rs               # Name of the ReplicaSet resource

# Specification of the desired state of the ReplicaSet.
spec:
  replicas: 3                  # Number of identical Pod replicas to maintain

  # The selector defines which Pods this ReplicaSet is responsible for managing.
  selector:
    matchLabels:
      app: nginx-rs            # Manages Pods with label 'app=nginx-rs'

  # The Pod template used to create Pods when replicas are missing.
  template:
    metadata:
      labels:
        app: nginx-rs          # Label on created Pods (must match the selector above)
    spec:
      containers:
      - name: nginx            # Name of the container running inside each Pod
        image: nginx:1.14      # Container image to use (nginx version 1.14)
        ports:
        - containerPort: 80    # Port exposed by the container for serving web traffic
```

> **Critical rule:** `template.metadata.labels` **must** match
> `spec.selector.matchLabels`. If they don't, the ReplicaSet can't recognize its own
> Pods and Kubernetes rejects the manifest.

---

## Step-by-Step Workflow

### Step 1 — Create the ReplicaSet

```bash
kubectl apply -f replicaset.yaml
```
Applies the configuration and creates the ReplicaSet along with its Pods.

### Step 2 — Verify the ReplicaSet was created

```bash
kubectl get rs
```
Lists all ReplicaSets with their **desired**, **current**, and **ready** replica
counts. You should see `nginx-rs` with `3` in each column.

### Step 3 — Check the Pods it created

```bash
kubectl get pods -o wide
```
Displays every Pod with its **node**, **IP**, and **image**, so you can confirm three
`nginx-rs` Pods are running.

### Step 4 — Verify the image in a specific Pod

```bash
kubectl describe pod <pod-name> | grep Image
```
Shows the container image the named Pod is actually running (should be `nginx:1.14`).

### Step 5 — Edit the ReplicaSet (e.g., change the image)

```bash
kubectl edit rs nginx-rs
```
Opens the live ReplicaSet definition in your editor. Change
`image: nginx:1.14` to a newer version (for example `nginx:1.16`) and save.

### Step 6 — Check the Pods after editing

```bash
kubectl get pods
```
**Expected:** the **same** Pods are still running the **old** image. Editing the
ReplicaSet alone does **not** replace existing Pods — this is the key difference from
a Deployment.

### Step 7 — Force Pods to restart with the new image

```bash
kubectl delete pod -l app=nginx-rs
```
Deletes all Pods with the label `app=nginx-rs`. The ReplicaSet immediately notices it
is below its desired count and recreates them — this time using the **new** image from
the updated template.

### Step 8 — Confirm the new Pods are running

```bash
kubectl get pods -o wide
```
Shows the freshly created Pods with new IPs and (via `describe`) the updated image.

---

## Why You Must Delete Pods to Update the Image

```
─────────────────────────────────────────────────────────────
 EDIT ONLY  (kubectl edit rs nginx-rs → nginx:1.16)
─────────────────────────────────────────────────────────────
   ReplicaSet template: nginx:1.16   ← updated
   Existing Pods:       nginx:1.14   ← UNCHANGED
   (ReplicaSet only applies the template to NEW pods)

─────────────────────────────────────────────────────────────
 AFTER DELETING PODS  (kubectl delete pod -l app=nginx-rs)
─────────────────────────────────────────────────────────────
   Pods deleted → ReplicaSet sees "current < desired"
        │
        ▼
   ReplicaSet recreates Pods from the CURRENT template
   New Pods: nginx:1.16   ← now updated
─────────────────────────────────────────────────────────────
```

A ReplicaSet only uses its Pod template when **creating** Pods. It never rebuilds Pods
that already exist. Deleting them triggers a fresh create from the current template —
which is why the manual delete in Step 7 is required.

---

## How the ReplicaSet Keeps Pods Alive

```
Desired: 3 replicas

   Pod A ✅   Pod B ✅   Pod C ✅       → current = 3, all good

   Pod B crashes / deleted:
   Pod A ✅   [   ]     Pod C ✅        → current = 2 < desired 3
        │
        ▼  reconciliation loop
   Pod A ✅   Pod D ✅   Pod C ✅       → new Pod D created, back to 3
```

The ReplicaSet controller runs a constant loop comparing **current** Pods to the
**desired** count and creates or removes Pods to match.

---

## Quick Reference Cheat Sheet

```bash
# Create / update
kubectl apply -f replicaset.yaml

# Inspect
kubectl get rs
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl describe pod <pod-name> | grep Image

# Edit the ReplicaSet
kubectl edit rs nginx-rs

# Force pods to adopt the new template
kubectl delete pod -l app=nginx-rs

# Scale up or down
kubectl scale rs nginx-rs --replicas=5

# Delete the ReplicaSet entirely
kubectl delete rs nginx-rs
```

---

## Troubleshooting Tips

- **Pods still show the old image after editing** — this is expected. Delete the Pods
  (`kubectl delete pod -l app=nginx-rs`) so the ReplicaSet recreates them from the new
  template.
- **`selector` errors on apply** — make sure `template.metadata.labels` exactly
  matches `spec.selector.matchLabels`.
- **Deleted Pods keep coming back** — that's the ReplicaSet doing its job. To stop
  Pods permanently, delete the ReplicaSet itself with `kubectl delete rs nginx-rs`.
- **`ImagePullBackOff` on new Pods** — the new image tag may be wrong or unavailable;
  verify the tag exists (e.g., `nginx:1.16`).
- **Wrong number of Pods** — check `kubectl get rs`; if desired ≠ ready, run
  `kubectl describe rs nginx-rs` and read the events at the bottom.

---

*Generated as a reference for the `nginx-rs` ReplicaSet practical.*
