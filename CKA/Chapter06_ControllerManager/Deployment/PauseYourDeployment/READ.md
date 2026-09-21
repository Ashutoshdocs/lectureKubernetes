# Kubernetes Deployment — Pause, Resume & ReplicaSet Cleanup

A hands-on practical that shows how to **batch multiple changes into a single
rollout** by pausing a Deployment, and how to **keep your cluster tidy** by limiting
the number of old ReplicaSets Kubernetes retains.

---

## Table of Contents

1. [Objectives](#objectives)
2. [Why This Matters](#why-this-matters)
3. [Key Concepts](#key-concepts)
4. [Prerequisites](#prerequisites)
5. [Step-by-Step Walkthrough](#step-by-step-walkthrough)
6. [How Pause / Resume Works](#how-pause--resume-works)
7. [How `revisionHistoryLimit` Works](#how-revisionhistorylimit-works)
8. [Important Commands](#important-commands)
9. [Interview Questions](#interview-questions)
10. [Troubleshooting Tips](#troubleshooting-tips)

---

## Objectives

By the end of this practical you will be able to:

1. **Pause** a Deployment rollout.
2. Apply **multiple changes** (image, scale, labels) while the rollout is paused.
3. **Resume** the Deployment and trigger a **single** rollout for all changes.
4. **Clean up** old ReplicaSets automatically using `revisionHistoryLimit`.

---

## Why This Matters

Every change to a Deployment's Pod template (like a new image) normally triggers its
own rollout and creates a new ReplicaSet. If you make five changes, you get five
rollouts and five ReplicaSets.

**Pausing** lets you stage several changes and roll them out **all at once**, which:

- Reduces churn and downtime risk from repeated Pod restarts.
- Creates a single, clean revision instead of many.

**`revisionHistoryLimit`** stops old, scaled-to-zero ReplicaSets from piling up and
wasting cluster resources.

---

## Key Concepts

| Term | What it does |
|------|--------------|
| **Pause** | Freezes rollouts. Changes are recorded but **not** applied to Pods yet. |
| **Resume** | Unfreezes the Deployment; all staged changes roll out together as one revision. |
| **Rollout** | The controlled process of replacing Pods to match a new template. |
| **ReplicaSet** | Ensures a set number of Pod replicas run. A new one is created per rollout. |
| **Revision** | A saved snapshot of the Deployment's Pod template. |
| **revisionHistoryLimit** | Max number of old ReplicaSets to keep for rollback. Extras are deleted. |

---

## Prerequisites

- A running Kubernetes cluster (Minikube, Kind, or any managed cluster).
- `kubectl` installed and configured to talk to your cluster.

---

## Step-by-Step Walkthrough

### Step 1 — Create the Deployment

Create a file called `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
```

Apply it and verify:

```bash
kubectl apply -f deployment.yaml

kubectl get deployment
kubectl get rs
kubectl get pods -o wide
```

You should see one Deployment, one ReplicaSet, and three Pods running `nginx:1.25`.

---

### Step 2 — Pause the Deployment

```bash
kubectl rollout pause deployment/nginx-deploy
```

Verify:

```bash
kubectl describe deployment nginx-deploy
```

**Expected:** the description shows `Deployment is paused`. From here, changes are
staged but not applied.

---

### Step 3 — Update the image (staged)

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.26
```

Verify:

```bash
kubectl get rs
```

**Expected:** **no new ReplicaSet** is created — the change is recorded only.

---

### Step 4 — Scale the Deployment (staged)

```bash
kubectl scale deployment nginx-deploy --replicas=5
```

Verify:

```bash
kubectl get deployment
```

> **Note:** Scaling is one of the few operations that can still take effect while
> paused, since it changes replica count rather than the Pod template. The image
> change, however, stays staged until you resume.

---

### Step 5 — Add a label (staged)

```bash
kubectl label deployment nginx-deploy env=prod
```

Verify:

```bash
kubectl get deployment --show-labels
```

---

### Step 6 — Confirm no rollout has happened

```bash
kubectl get rs
kubectl rollout history deployment/nginx-deploy
```

**Expected:** only the **original** ReplicaSet exists. Despite three separate
changes, no new rollout has been triggered because the Deployment is paused.

---

### Step 7 — Resume the Deployment

```bash
kubectl rollout resume deployment/nginx-deploy
```

Monitor and verify:

```bash
kubectl rollout status deployment/nginx-deploy
kubectl get rs
kubectl get pods
```

**Expected:** a **single new ReplicaSet** is created that carries **all** the staged
changes at once (new image + new replica count).

---

### Step 8 — Create multiple revisions

Now generate several revisions to demonstrate history buildup:

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.27
kubectl rollout status deployment/nginx-deploy

kubectl set image deployment/nginx-deploy nginx=nginx:1.28
kubectl rollout status deployment/nginx-deploy

kubectl set image deployment/nginx-deploy nginx=latest
```

Verify:

```bash
kubectl get rs
```

**Expected:** several ReplicaSets now exist — the active one plus older ones scaled
to 0.

> **Tip:** Using the bare `latest` tag (or `nginx=latest`) is fine for practice but
> avoid it in production — you can't tell which version is actually deployed, and
> rollbacks become unpredictable. Prefer explicit tags like `nginx:1.28`.

---

### Step 9 — Configure ReplicaSet cleanup

Edit the Deployment:

```bash
kubectl edit deployment nginx-deploy
```

Add `revisionHistoryLimit` under `spec`:

```yaml
spec:
  replicas: 5
  revisionHistoryLimit: 2
```

This tells Kubernetes to keep only the **2 most recent** old ReplicaSets.

---

### Step 10 — Trigger another rollout

```bash
kubectl set image deployment/nginx-deploy nginx=1.29
kubectl rollout status deployment/nginx-deploy
```

---

### Step 11 — Verify the cleanup

```bash
kubectl get rs
```

**Expected:** only the current ReplicaSet plus the **last two** old ReplicaSets
remain. Older ones have been automatically deleted.

---

## How Pause / Resume Works

```
─────────────────────────────────────────────────────────────
 PAUSED
─────────────────────────────────────────────────────────────
   kubectl rollout pause
        │
        ├─ set image  nginx:1.26   ─┐
        ├─ scale      replicas=5    │  changes STAGED,
        └─ label      env=prod     ─┘  no new ReplicaSet

   ReplicaSet v1 (unchanged) ──▶ Pods

─────────────────────────────────────────────────────────────
 RESUMED
─────────────────────────────────────────────────────────────
   kubectl rollout resume
        │
        ▼
   Deployment ──▶ ReplicaSet v2 (all changes) ──▶ Pods
                  ReplicaSet v1 (scaled to 0)

   → ONE rollout, ONE new revision for all staged changes
─────────────────────────────────────────────────────────────
```

While paused, the Deployment controller records your intent but does not reconcile
the Pods. On resume, it computes the final desired state and rolls out **once**.

---

## How `revisionHistoryLimit` Works

```
Before cleanup (revisionHistoryLimit not set / default 10):
   RS-current  (active)
   RS-old-1    (0 replicas)
   RS-old-2    (0 replicas)
   RS-old-3    (0 replicas)
   RS-old-4    (0 replicas)   ← accumulating

After setting revisionHistoryLimit: 2 and a new rollout:
   RS-current  (active)
   RS-old-1    (0 replicas)   ┐ only the two most
   RS-old-2    (0 replicas)   ┘ recent are kept
   (older ReplicaSets deleted automatically)
```

- **Default** is `10` if you don't set it.
- Old ReplicaSets are kept **only** so you can roll back. Deleting them frees etcd
  and cluster resources but reduces how far back you can roll.
- Setting it too low (e.g., `0`) means you lose rollback capability entirely.

---

## Important Commands

```bash
# Create / apply
kubectl apply -f deployment.yaml

# Pause & resume
kubectl rollout pause  deployment/nginx-deploy
kubectl rollout resume deployment/nginx-deploy

# Monitor & history
kubectl rollout status  deployment/nginx-deploy
kubectl rollout history deployment/nginx-deploy

# Make changes
kubectl set image deployment/nginx-deploy nginx=nginx:1.26
kubectl scale    deployment nginx-deploy --replicas=5
kubectl label    deployment nginx-deploy env=prod

# Inspect & edit
kubectl get rs
kubectl edit deployment nginx-deploy
```

---

## Interview Questions

**Q. Why pause a Deployment?**
A. To apply multiple changes together and produce only a single rollout instead of
one per change.

**Q. What happens when a Deployment is paused?**
A. Changes are recorded (staged) but no new ReplicaSet is created and no Pods are
updated until you resume.

**Q. Why use `revisionHistoryLimit`?**
A. To automatically delete old, unused ReplicaSets and save cluster resources, while
still keeping a set number for rollbacks.

**Q. Does scaling work while paused?**
A. Yes — scaling changes the replica count rather than the Pod template, so it can
still take effect, unlike an image change which stays staged until resume.

---

## Troubleshooting Tips

- **New ReplicaSet appears while "paused"** — confirm the pause actually applied with
  `kubectl describe deployment nginx-deploy` (look for `Deployment is paused`).
- **Resume doesn't roll out** — there may be no *template* change staged. Only Pod
  template changes trigger a new ReplicaSet; scaling alone does not.
- **Old ReplicaSets not deleted** — cleanup happens on the **next rollout** after
  setting `revisionHistoryLimit`, not immediately.
- **Can't roll back far enough** — your `revisionHistoryLimit` may be too low; older
  revisions have already been pruned.
- **`ImagePullBackOff` after an update** — verify the image tag exists (e.g.,
  `nginx:1.29` vs a typo). Avoid the bare `latest` tag in real environments.

---

*Generated as a reference for the `nginx-deploy` pause/resume and ReplicaSet cleanup practical.*
