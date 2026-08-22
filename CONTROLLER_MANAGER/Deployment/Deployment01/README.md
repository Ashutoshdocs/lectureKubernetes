# Kubernetes Deployment Lifecycle — nginx-deploy

A hands-on guide to creating, updating, rolling back, and inspecting a Kubernetes
**Deployment** using `kubectl`. This README walks through the full lifecycle of an
`nginx` Deployment, from the initial YAML definition to image upgrades and rollbacks.

---

## Table of Contents

1. [Overview](#overview)
2. [Key Concepts](#key-concepts)
3. [The Deployment Manifest (`deployment.yaml`)](#the-deployment-manifest-deploymentyaml)
4. [Step-by-Step Workflow](#step-by-step-workflow)
5. [Rollout & Rollback Commands](#rollout--rollback-commands)
6. [Inspecting ReplicaSets](#inspecting-replicasets)
7. [Deployment Lifecycle Diagram](#deployment-lifecycle-diagram)
8. [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet)
9. [Troubleshooting Tips](#troubleshooting-tips)

---

## Overview

A **Deployment** is a Kubernetes object that manages a set of identical Pods. It
guarantees a declared number of replicas are running, handles rolling updates when
you change the Pod template (e.g., a new image), and keeps a history so you can roll
back to any previous revision.

When you apply a Deployment, Kubernetes creates a chain of resources:

```
Deployment ──▶ ReplicaSet ──▶ Pods
```

- The **Deployment** describes the desired state.
- The **ReplicaSet** ensures the correct number of Pod copies exist.
- The **Pods** are the actual running containers.

---

## Key Concepts

| Term | What it does |
|------|--------------|
| **Deployment** | High-level controller that manages ReplicaSets and rolling updates. |
| **ReplicaSet** | Ensures a specified number of Pod replicas are running. Created automatically by the Deployment. |
| **Pod** | The smallest deployable unit; wraps one or more containers. |
| **Replica** | A running copy of a Pod. `replicas: 3` means three identical Pods. |
| **Rollout** | The process of applying a change (like a new image) across Pods. |
| **Revision** | A saved snapshot of a Deployment's Pod template, used for rollbacks. |
| **Selector** | Labels the Deployment uses to know which Pods it owns. |

---

## The Deployment Manifest (`deployment.yaml`)

This YAML file declares the desired state of the Deployment. Every command in this
guide starts from this definition.

```yaml
# The API version used for Deployments. 'apps/v1' is the stable version.
apiVersion: apps/v1

# The resource type we are creating. In this case, it's a Deployment.
kind: Deployment

# Metadata section defines identifying information for the Deployment.
metadata:
  name: nginx-deploy          # Name of the Deployment resource

# Specification of the desired behavior of the Deployment.
spec:
  replicas: 3                 # Number of Pod replicas that should be running at any time

  # The selector defines how the Deployment finds which Pods to manage.
  selector:
    matchLabels:
      app: nginx              # Matches Pods that have label 'app=nginx'

  # The template defines the Pod configuration created by the Deployment.
  template:
    metadata:
      labels:
        app: nginx            # Label on Pods created here (must match the selector)
    spec:
      containers:
      - name: nginx           # Name of the container running inside each Pod
        image: nginx:1.14     # Container image used for deployment (Nginx 1.14)
        ports:
        - containerPort: 80   # Port exposed by the container (Nginx listens on 80)
```

> **Note:** The labels under `template.metadata.labels` **must** match the
> `selector.matchLabels`. If they don't, the Deployment cannot adopt its Pods and
> Kubernetes will reject the manifest.

---

## Step-by-Step Workflow

### Step 1 — Create or update the Deployment

```bash
kubectl apply -f deployment.yaml
```
Applies the configuration. On first run this creates the **Deployment**,
**ReplicaSet**, and **Pods**. On later runs it updates them to match the file.

### Step 2 — Verify the Deployment was created

```bash
kubectl get deployment
```
Lists all Deployments, showing **desired**, **current**, **up-to-date**, and
**available** replica counts.

### Step 3 — Check the ReplicaSet

```bash
kubectl get rs
```
Displays the ReplicaSets managed by the Deployment (auto-created by Kubernetes).

### Step 4 — View running Pods with details

```bash
kubectl get pods -o wide
```
Shows each Pod's **IP**, **node**, and **image**, useful for verification.

### Step 5 — Update the container image

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.16
```
Changes the `nginx` container image to version **1.16**. This triggers a rolling
update: a new ReplicaSet is created and Pods are gradually replaced.

### Step 6 — Monitor the rollout

```bash
kubectl rollout status deployment/nginx-deploy
```
Streams live progress of the update until all Pods are running the new image.

### Step 7 — Recheck the ReplicaSets

```bash
kubectl get rs
```
You should now see **two** ReplicaSets: the old one (scaled to 0) and the new one
(scaled to your replica count) with the updated image.

### Step 8 — Verify the new Pods

```bash
kubectl get pods -o wide
```
Confirms the new Pods are running the new image with fresh IPs.

### Step 9 — Confirm the image inside a specific Pod

```bash
kubectl describe pod <pod-name> | grep Image
```
Displays the exact container image the specified Pod is running.

### Step 10 — Roll back if something is wrong

```bash
kubectl rollout undo deployment/nginx-deploy
```
Reverts to the previous working revision of the Deployment.

### Step 11 — Check the rollout status after rollback

```bash
kubectl rollout status deployment/nginx-deploy
```
Verifies the rollback finished and the Pods are healthy.

### Step 12 — View the rollout history

```bash
kubectl rollout history deployment/nginx-deploy
```
Lists all saved revisions so you can track what changed and when.

### Step 13 — Check ReplicaSets after rollback

```bash
kubectl get rs
```
Confirms which ReplicaSet is now active following the rollback.

---

## Rollout & Rollback Commands

These commands give you fine-grained control over revisions.

```bash
# Show all rollout revisions
kubectl rollout history deployment/nginx-deploy

# Inspect the details of a specific revision (e.g., revision 3)
kubectl rollout history deployment/nginx-deploy --revision=3

# Roll back to the immediately previous revision
kubectl rollout undo deployment/nginx-deploy

# Roll back to a specific revision (e.g., revision 2)
kubectl rollout undo deployment/nginx-deploy --to-revision=2
```

| Command | Purpose |
|---------|---------|
| `rollout history` | List every saved revision. |
| `rollout history --revision=N` | Show the Pod template details of revision **N**. |
| `rollout undo` | Revert to the last revision. |
| `rollout undo --to-revision=N` | Revert to a specific revision **N**. |

---

## Inspecting ReplicaSets

Useful commands for looking closely at ReplicaSets and the images they run.

```bash
# List all ReplicaSets
kubectl get rs

# Full details of a single ReplicaSet
kubectl describe rs <replicaset-name>

# Custom columns: show each ReplicaSet's name and container image
kubectl get rs -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image
```

The custom-columns output is handy for quickly seeing **which image each ReplicaSet
was built with**, making it easy to tell the old and new versions apart.

---

## Deployment Lifecycle Diagram

```
─────────────────────────────────────────────────────────────
 INITIAL STATE  (kubectl apply -f deployment.yaml)
─────────────────────────────────────────────────────────────
   Deployment ──▶ ReplicaSet v1 (nginx:1.14) ──▶ Pods (3x)
     • v1 ReplicaSet manages 3 Pods running nginx:1.14

─────────────────────────────────────────────────────────────
 AFTER UPDATE  (kubectl set image ... nginx=nginx:1.16)
─────────────────────────────────────────────────────────────
   Deployment ──▶ ReplicaSet v2 (nginx:1.16) ──▶ Pods (3x)
                  ReplicaSet v1 (kept for rollback, scaled to 0)
     • v2 created automatically
     • v1 retained but inactive (0 replicas)

─────────────────────────────────────────────────────────────
 AFTER ROLLBACK  (kubectl rollout undo ...)
─────────────────────────────────────────────────────────────
   Deployment ──▶ ReplicaSet v1 (reactivated) ──▶ Pods (3x)
                  ReplicaSet v2 (scaled to 0)
     • v1 reactivated with the previous image
     • v2 scaled down but kept in history
─────────────────────────────────────────────────────────────
```

Key takeaway: Kubernetes **never deletes** the old ReplicaSet during an update. It
scales it to zero and keeps it, which is exactly what makes instant rollbacks
possible.

---

## Quick Reference Cheat Sheet

```bash
# Create / update
kubectl apply -f deployment.yaml

# Inspect
kubectl get deployment
kubectl get rs
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl describe rs <replicaset-name>

# Update image
kubectl set image deployment/nginx-deploy nginx=nginx:1.16

# Rollout control
kubectl rollout status  deployment/nginx-deploy
kubectl rollout history deployment/nginx-deploy
kubectl rollout undo    deployment/nginx-deploy
kubectl rollout undo    deployment/nginx-deploy --to-revision=2
```

---

## Troubleshooting Tips

- **Pods stuck in `ImagePullBackOff`** — the image name or tag is likely wrong.
  Double-check `nginx:1.16` exists and is spelled correctly.
- **Rollout hangs** — a new Pod may be failing its readiness/liveness checks. Run
  `kubectl describe pod <pod-name>` and check the events at the bottom.
- **`selector` errors on apply** — ensure `template.metadata.labels` matches
  `spec.selector.matchLabels` exactly.
- **No rollback history** — history is only kept up to `revisionHistoryLimit`
  (default 10). Older revisions are pruned automatically.
- **Change not taking effect** — a Deployment only rolls out when the Pod *template*
  changes. Editing something outside `spec.template` won't trigger a new rollout.

---

*Generated as a reference for the `nginx-deploy` Kubernetes Deployment workflow.*
