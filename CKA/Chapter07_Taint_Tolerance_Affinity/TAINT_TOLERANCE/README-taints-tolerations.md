# Kubernetes Scheduling Demo: Taints & Tolerations

A hands-on demonstration of how **Kubernetes node taints** control Pod scheduling and how **Pod tolerations** allow selected Pods to run on tainted nodes.

The demo covers all three major taint effects:

* `NoSchedule`
* `PreferNoSchedule`
* `NoExecute`

---

## What You'll Learn

| Concept              | Owner | Purpose                                                          |
| -------------------- | ----- | ---------------------------------------------------------------- |
| **Taint**            | Node  | Repels Pods that do not tolerate the taint                       |
| **Toleration**       | Pod   | Allows a Pod to be scheduled on a tainted node                   |
| **NoSchedule**       | Node  | Blocks new Pods without a matching toleration                    |
| **PreferNoSchedule** | Node  | Tries to avoid placing Pods on the node                          |
| **NoExecute**        | Node  | Blocks new Pods and removes existing Pods that don't tolerate it |

### Core concept

```text
              NODE
                │
             TAINT
                │
        ┌───────┴────────┐
        │                │
   No Toleration    Matching Toleration
        │                │
        ▼                ▼
      REJECT           ALLOW
```

> **Taints repel; tolerations permit.**

A toleration does **not** force a Pod onto a node. It only removes the taint as a scheduling restriction.

---

# Prerequisites

You need:

* A running Kubernetes cluster
* At least one worker node
* `kubectl` configured
* A node named `worker`

Check your nodes:

```bash
kubectl get nodes
```

Example:

```text
NAME      STATUS   ROLES           AGE
master    Ready    control-plane   10d
worker    Ready    <none>          10d
```

Watch Pods in another terminal:

```bash
kubectl get pods -o wide -w
```

---

# Taint Structure

A taint has three important parts:

```text
key=value:effect
```

Example:

```text
env=prod:NoSchedule
```

Meaning:

```text
key     = env
value   = prod
effect  = NoSchedule
```

A matching toleration looks like:

```yaml
tolerations:
  - key: env
    operator: Equal
    value: prod
    effect: NoSchedule
```

The taint and toleration match:

```text
Node Taint
env=prod:NoSchedule
       │
       │ matches
       ▼
Pod Toleration
key=env
operator=Equal
value=prod
effect=NoSchedule
```

---

# Three Taint Effects

## 1. NoSchedule

```text
NoSchedule
```

### Behavior

New Pods that do not tolerate the taint:

```text
             worker
               │
       env=prod:NoSchedule
               │
               ▼
       ┌───────────────┐
       │ Pod without   │
       │ toleration    │
       └───────┬───────┘
               │
               X
            REJECTED
```

Existing Pods already running on the node remain there.

### Important

```text
NoSchedule
    │
    ├── Existing Pods → Stay
    │
    └── New Pods → Blocked
```

---

# 2. PreferNoSchedule

```text
PreferNoSchedule
```

This is a **soft restriction**.

The scheduler tries to avoid the tainted node, but it can still place a Pod there if there is no better scheduling option.

```text
             worker
               │
    env=prod:PreferNoSchedule
               │
               ▼
       Scheduler tries
       to avoid node
               │
       ┌───────┴────────┐
       │                │
Other suitable      No suitable
node available      alternative
       │                │
       ▼                ▼
  Use other node    May use worker
```

### Important

```text
PreferNoSchedule
        │
        ├── Soft restriction
        ├── Scheduler tries to avoid node
        └── Pod may still run there
```

> Because this is a preference rather than a hard prohibition, the exact placement depends on the other nodes and scheduling constraints in the cluster.

---

# 3. NoExecute

```text
NoExecute
```

This is stronger than `NoSchedule`.

It affects both:

1. **New Pods**
2. **Existing Pods**

```text
             worker
               │
       env=prod:NoExecute
               │
        ┌──────┴──────┐
        │             │
   New Pod        Existing Pod
        │             │
        ▼             ▼
     BLOCKED        EVICTED
```

### Important

```text
NoExecute
    │
    ├── New Pod without toleration → Blocked
    │
    └── Existing Pod without toleration → Evicted
```

A Pod can use:

```yaml
tolerationSeconds: 30
```

to tolerate a `NoExecute` taint temporarily.

Example:

```yaml
tolerations:
  - key: env
    operator: Equal
    value: prod
    effect: NoExecute
    tolerationSeconds: 30
```

The Pod can remain on the node for 30 seconds after the taint is applied, unless the taint is removed.

---

# Demo 1 — NoSchedule

## Step 1: Apply the taint

```bash
kubectl taint nodes worker env=prod:NoSchedule
```

Verify:

```bash
kubectl describe node worker | grep -i taints
```

Expected:

```text
Taints: env=prod:NoSchedule
```

---

## Step 2: Create Pod WITHOUT toleration

Create:

### `pod-no-toleration.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-no-toleration

spec:
  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-no-toleration.yaml
```

Check:

```bash
kubectl get pod nginx-no-toleration -o wide
```

Expected:

```text
NAME                  READY   STATUS    NODE
nginx-no-toleration   0/1     Pending   <none>
```

Check the reason:

```bash
kubectl describe pod nginx-no-toleration
```

Look at the **Events** section.

You should see an event indicating that the Pod cannot be scheduled because of an untolerated taint.

---

## Step 3: Delete the Pod

```bash
kubectl delete -f pod-no-toleration.yaml
```

---

## Step 4: Create Pod WITH toleration

Create:

### `pod-with-toleration.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-with-toleration

spec:

  tolerations:
    - key: env
      operator: Equal
      value: prod
      effect: NoSchedule

  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-with-toleration.yaml
```

Check:

```bash
kubectl get pod nginx-with-toleration -o wide
```

The Pod is now allowed to run on the tainted node.

---

# Demo 2 — PreferNoSchedule

First remove the previous taint:

```bash
kubectl taint nodes worker env=prod:NoSchedule-
```

Apply a soft taint:

```bash
kubectl taint nodes worker env=prod:PreferNoSchedule
```

Verify:

```bash
kubectl describe node worker | grep -i taints
```

Expected:

```text
Taints: env=prod:PreferNoSchedule
```

---

## Create a Pod WITHOUT toleration

Create:

### `pod-prefer.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-prefer

spec:
  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-prefer.yaml
```

Check:

```bash
kubectl get pod nginx-prefer -o wide
```

### Important observation

Unlike `NoSchedule`, the Pod is **not guaranteed to remain Pending**.

The scheduler will generally prefer another suitable node.

If no better option exists, the Pod can still be scheduled on `worker`.

Therefore, this command:

```bash
kubectl get pod nginx-prefer -o wide
```

is the important part of the demonstration.

---

# Demo 3 — NoExecute

Delete the previous Pod:

```bash
kubectl delete -f pod-prefer.yaml
```

Remove the `PreferNoSchedule` taint:

```bash
kubectl taint nodes worker env=prod:PreferNoSchedule-
```

---

## Step 1: Run a Pod on worker

For a predictable demonstration, create:

### `pod-test.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-test

spec:

  nodeSelector:
    kubernetes.io/hostname: worker

  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-test.yaml
```

Verify:

```bash
kubectl get pod nginx-test -o wide
```

You should see:

```text
NAME         READY   STATUS    NODE
nginx-test   1/1     Running   worker
```

---

## Step 2: Apply NoExecute taint

```bash
kubectl taint nodes worker env=prod:NoExecute
```

Verify:

```bash
kubectl describe node worker | grep -i taints
```

Expected:

```text
Taints: env=prod:NoExecute
```

---

## Step 3: Watch the Pod

```bash
kubectl get pod nginx-test -o wide -w
```

The existing Pod does not tolerate the `NoExecute` taint.

Therefore Kubernetes removes it from the node.

Check:

```bash
kubectl get pods
```

The Pod will be terminated.

---

# Demo 4 — NoExecute with Toleration

Now demonstrate that a Pod can remain on the node when it tolerates the `NoExecute` taint.

Create:

### `pod-noexecute.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-noexecute

spec:

  nodeSelector:
    kubernetes.io/hostname: worker

  tolerations:
    - key: env
      operator: Equal
      value: prod
      effect: NoExecute

  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-noexecute.yaml
```

Check:

```bash
kubectl get pod nginx-noexecute -o wide
```

Expected:

```text
NAME              READY   STATUS    NODE
nginx-noexecute   1/1     Running   worker
```

The Pod remains on `worker` because it tolerates:

```text
env=prod:NoExecute
```

---

# Demo 5 — NoExecute + tolerationSeconds

This demonstrates temporary tolerance.

Create:

### `pod-noexecute-timer.yaml`

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-timer

spec:

  nodeSelector:
    kubernetes.io/hostname: worker

  tolerations:
    - key: env
      operator: Equal
      value: prod
      effect: NoExecute
      tolerationSeconds: 30

  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f pod-noexecute-timer.yaml
```

Watch:

```bash
kubectl get pod nginx-timer -o wide -w
```

The Pod initially runs on `worker`.

After the `NoExecute` taint is applied, the Pod tolerates it for approximately 30 seconds.

After the tolerance period expires, Kubernetes evicts the Pod.

---

# Comparing the Three Effects

| Effect             | New Pod without toleration | Existing Pod without toleration | Type            |
| ------------------ | -------------------------- | ------------------------------- | --------------- |
| `NoSchedule`       | Blocked                    | Stays                           | Hard            |
| `PreferNoSchedule` | Scheduler tries to avoid   | Stays                           | Soft            |
| `NoExecute`        | Blocked                    | Evicted                         | Hard + eviction |

### Remember

```text
NoSchedule
    ↓
Block NEW Pods


PreferNoSchedule
    ↓
TRY to avoid NEW Pods


NoExecute
    ↓
Block NEW Pods
+
Evict EXISTING Pods
```

---

# Taints vs Tolerations

Think about the direction of control:

```text
             TAINT
               │
               ▼
        ┌──────────────┐
        │     NODE     │
        └──────┬───────┘
               │
          "I don't want
           these Pods"
               │
               ▼
        ┌──────────────┐
        │     POD      │
        └──────┬───────┘
               │
          TOLERATION
               │
               ▼
        "I can tolerate
          this taint"
```

---

# Taints vs Affinity

These concepts work in opposite directions.

### Taints

The **Node** says:

```text
"I don't want certain Pods."
```

### Toleration

The **Pod** says:

```text
"I am allowed to be here."
```

### Affinity

The **Pod** says:

```text
"I prefer/want this type of Node."
```

Therefore:

```text
Taint
Node ──────────────► Repels Pod


Toleration
Pod ───────────────► Can tolerate Node


Affinity
Pod ───────────────► Attracts itself to Node
```

---

# Recommended Real-World Combination

Taints and affinity are often used together.

For example:

```text
Dedicated Production Node
        │
        ├── Taint
        │   env=prod:NoSchedule
        │
        └── Only production Pods
              │
              ├── Toleration
              │
              └── Node Affinity
```

The toleration allows the Pod to use the node.

The node affinity helps ensure the Pod actually chooses that node.

---

# Cleanup

Remove all demonstration Pods:

```bash
kubectl delete -f pod-no-toleration.yaml --ignore-not-found
kubectl delete -f pod-with-toleration.yaml --ignore-not-found
kubectl delete -f pod-prefer.yaml --ignore-not-found
kubectl delete -f pod-test.yaml --ignore-not-found
kubectl delete -f pod-noexecute.yaml --ignore-not-found
kubectl delete -f pod-noexecute-timer.yaml --ignore-not-found
```

Remove the taint:

```bash
kubectl taint nodes worker env=prod:NoExecute-
```

If you used `PreferNoSchedule`:

```bash
kubectl taint nodes worker env=prod:PreferNoSchedule- --ignore-not-found
```

If you used `NoSchedule`:

```bash
kubectl taint nodes worker env=prod:NoSchedule- --ignore-not-found
```

Verify:

```bash
kubectl describe node worker | grep -i taints
```

---

# Quick CKA Cheat Sheet

```text
┌─────────────────────────────────────────────────────────┐
│                  KUBERNETES TAINTS                      │
├─────────────────────┬───────────────────────────────────┤
│ NoSchedule          │ Block NEW Pods                    │
│                     │ Existing Pods stay                │
├─────────────────────┼───────────────────────────────────┤
│ PreferNoSchedule    │ TRY to avoid node                 │
│                     │ Pod may still be scheduled        │
├─────────────────────┼───────────────────────────────────┤
│ NoExecute           │ Block NEW Pods                    │
│                     │ Evict EXISTING Pods               │
└─────────────────────┴───────────────────────────────────┘
```

## One-line memory trick

```text
NoSchedule       → Don't Schedule
PreferNoSchedule → Prefer another node
NoExecute        → Don't Execute + Evict
```

## Core Rule

```text
TAINT = Node says "Stay Away"

TOLERATION = Pod says "I can tolerate it"

AFFINITY = Pod says "I want this node"
```
