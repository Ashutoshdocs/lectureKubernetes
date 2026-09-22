# Kubernetes Pod Affinity — `topologyKey` Teaching Demo

## 1. Learning Objective

This demo explains **Pod Affinity** and, most importantly, the meaning of `topologyKey`.

> **Takeaway:** `topologyKey` defines what counts as **"together."**

Examples:

- `kubernetes.io/hostname` → **together = same node**
- `topology.kubernetes.io/zone` → **together = same availability zone**

Pod affinity is used when one workload benefits from being **co-located** with another workload.

### Example

Suppose we have:

```text
Frontend Pod
     |
     | benefits from being close to
     v
Backend Pod
```

With Pod Affinity, Kubernetes can be instructed:

> "Place this Pod on a topology domain where a matching Pod already exists."

---

# 2. What We Will Demonstrate

We will create:

```text
Namespace
   |
   +-- Backend Deployment
   |      |
   |      +-- backend Pods
   |
   +-- Frontend Deployment
          |
          +-- frontend Pods
```

The frontend Pods will have an **affinity rule** saying:

```text
Find Pods with:
    app=backend

and place me in the same:
    kubernetes.io/hostname
```

Therefore:

```text
                 Kubernetes Cluster
          +-----------------------------+
          |                             |
          |   Node 1                    |   Node 2
          |   hostname=node-1           |   hostname=node-2
          |                             |
          |   backend-xxxxx             |   backend-yyyyy
          |   frontend-xxxxx            |
          |   frontend-yyyyy             |
          |                             |
          +-----------------------------+
```

The important point is **not** that frontend must use a particular node.

The rule says:

> Frontend must be placed in the **same topology domain** as a matching backend Pod.

With `kubernetes.io/hostname`, the topology domain is the **node**.

---

# 3. Important Concepts

## 3.1 Pod Affinity

Pod affinity tells the scheduler:

> Prefer or require placing this Pod close to other Pods that match a label.

It is useful for workloads such as:

- frontend + backend
- application + cache
- application + local data service
- tightly coupled microservices

---

## 3.2 `topologyKey`

`topologyKey` tells Kubernetes **what "close" means**.

### Same Node

```yaml
topologyKey: kubernetes.io/hostname
```

Meaning:

```text
Same hostname label
        =
Same Kubernetes node
```

### Same Zone

```yaml
topologyKey: topology.kubernetes.io/zone
```

Meaning:

```text
Same zone
```

For example:

```text
Zone A
  ├── Node 1
  └── Node 2

Zone B
  ├── Node 3
  └── Node 4
```

With:

```yaml
topologyKey: topology.kubernetes.io/zone
```

the scheduler can place the Pod on **any node in the same zone** as the matching Pod.

---

# 4. `requiredDuringSchedulingIgnoredDuringExecution`

This is the strict form of Pod Affinity.

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
```

It means:

> The rule is a hard requirement during scheduling.

If Kubernetes cannot find a suitable topology domain, the Pod remains:

```text
Pending
```

The scheduler does **not** simply ignore the rule.

### Meaning of the name

```text
requiredDuringScheduling
        |
        +-- Must satisfy the rule when scheduling

IgnoredDuringExecution
        |
        +-- Existing Pod is not automatically evicted
            if the condition later changes
```

---

# 5. `labelSelector`

The affinity rule needs to know:

> Which Pods am I trying to be close to?

Example:

```yaml
labelSelector:
  matchExpressions:
    - key: app
      operator: In
      values:
        - backend
```

This selects Pods having:

```yaml
labels:
  app: backend
```

So the scheduler effectively evaluates:

```text
Find backend Pods
        |
        v
Find their topology domain
        |
        v
Place frontend in that domain
```

---

# 6. Demo Architecture

We will use:

```text
backend Deployment
        |
        | label
        v
    app=backend

frontend Deployment
        |
        | Pod Affinity
        v
"Find app=backend Pods
 and place me in the same hostname"
```

Files:

```text
pod-affinity-demo/
├── 01-namespace.yaml
├── 02-backend.yaml
├── 03-frontend-affinity.yaml
└── 04-zone-affinity.yaml
```

---

# 7. Prerequisites

Use a Kubernetes cluster with **at least 2 worker nodes**.

Check:

```bash
kubectl get nodes -L kubernetes.io/hostname -L topology.kubernetes.io/zone
```

Example:

```text
NAME       STATUS   ROLES    AGE   VERSION   kubernetes.io/hostname   topology.kubernetes.io/zone
worker-1   Ready    <none>   ...   ...       worker-1                 zone-a
worker-2   Ready    <none>   ...   ...       worker-2                 zone-b
```

> If your cluster has only one worker node, the same-node affinity rule will still work, but the teaching demonstration will not visibly show scheduling choices across nodes.

---

# 8. Step 1 — Create Namespace

Create:

## `01-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: affinity-demo
```

Apply:

```bash
kubectl apply -f 01-namespace.yaml
```

Verify:

```bash
kubectl get namespace affinity-demo
```

Expected:

```text
NAME            STATUS
affinity-demo   Active
```

---

# 9. Step 2 — Deploy Backend

Create:

## `02-backend.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: affinity-demo
spec:
  replicas: 2

  selector:
    matchLabels:
      app: backend

  template:
    metadata:
      labels:
        app: backend

    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
```

Apply:

```bash
kubectl apply -f 02-backend.yaml
```

Check:

```bash
kubectl get pods -n affinity-demo -o wide
```

Example:

```text
NAME                       READY   STATUS    NODE
backend-xxxxx              1/1     Running   worker-1
backend-yyyyy              1/1     Running   worker-2
```

The exact node placement can differ.

---

# 10. Step 3 — Understand the Backend Labels

Run:

```bash
kubectl get pods -n affinity-demo --show-labels
```

You should see:

```text
NAME                       LABELS
backend-xxxxx              app=backend
backend-yyyyy              app=backend
```

This label is important because the frontend affinity rule will search for:

```yaml
app: backend
```

---

# 11. Step 4 — Deploy Frontend with Pod Affinity

Create:

## `03-frontend-affinity.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: affinity-demo

spec:
  replicas: 2

  selector:
    matchLabels:
      app: frontend

  template:
    metadata:
      labels:
        app: frontend

    spec:

      affinity:

        podAffinity:

          requiredDuringSchedulingIgnoredDuringExecution:

            - labelSelector:

                matchExpressions:

                  - key: app
                    operator: In
                    values:
                      - backend

              topologyKey: kubernetes.io/hostname

      containers:

        - name: nginx

          image: nginx:alpine

          ports:

            - containerPort: 80
```

Apply:

```bash
kubectl apply -f 03-frontend-affinity.yaml
```

---

# 12. Step 5 — Observe Scheduling

Run:

```bash
kubectl get pods -n affinity-demo -o wide
```

Example:

```text
NAME                        READY   STATUS    NODE
backend-aaaaa               1/1     Running   worker-1
backend-bbbbb               1/1     Running   worker-2

frontend-ccccc              1/1     Running   worker-1
frontend-ddddd              1/1     Running   worker-2
```

Why?

Because:

```text
frontend-ccccc
      |
      +--> finds backend-aaaaa
      |
      +--> backend is on worker-1
      |
      +--> topologyKey = hostname
      |
      +--> frontend must be on worker-1
```

And similarly:

```text
frontend-ddddd
      |
      +--> finds backend-bbbbb
      |
      +--> backend is on worker-2
      |
      +--> frontend must be on worker-2
```

The exact result depends on the scheduler and the available topology.

---

# 13. The Most Important Diagram

```text
                    Pod Affinity
                         |
                         v
              labelSelector: app=backend
                         |
                         v
                Find matching Pods
                         |
                         v
                 topologyKey
                         |
             +-----------+-----------+
             |                       |
             v                       v
kubernetes.io/hostname     topology.kubernetes.io/zone
             |                       |
             v                       v
          Same Node               Same Zone
```

Remember:

```text
topologyKey = "What does together mean?"
```

---

# 14. Verify Node Labels

Run:

```bash
kubectl get nodes --show-labels
```

Look for:

```text
kubernetes.io/hostname=worker-1
```

and:

```text
topology.kubernetes.io/zone=zone-a
```

You can inspect a specific node:

```bash
kubectl get node worker-1 --show-labels
```

Or:

```bash
kubectl describe node worker-1
```

---

# 15. Step 6 — Demonstrate Same Zone

The previous example used:

```yaml
topologyKey: kubernetes.io/hostname
```

Now change the topology level.

Create:

## `04-zone-affinity.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-zone
  namespace: affinity-demo

spec:
  replicas: 2

  selector:
    matchLabels:
      app: frontend-zone

  template:
    metadata:
      labels:
        app: frontend-zone

    spec:

      affinity:

        podAffinity:

          requiredDuringSchedulingIgnoredDuringExecution:

            - labelSelector:

                matchExpressions:

                  - key: app
                    operator: In
                    values:
                      - backend

              topologyKey: topology.kubernetes.io/zone

      containers:

        - name: nginx

          image: nginx:alpine

          ports:

            - containerPort: 80
```

Apply:

```bash
kubectl apply -f 04-zone-affinity.yaml
```

---

# 16. Compare the Two Topology Keys

## `kubernetes.io/hostname`

```text
Backend
   |
   v
Same NODE
```

Example:

```text
worker-1
  ├── backend
  └── frontend
```

---

## `topology.kubernetes.io/zone`

```text
Backend
   |
   v
Same ZONE
```

Example:

```text
Zone-A
  ├── worker-1
  │     └── backend
  │
  └── worker-2
        └── frontend
```

The frontend does **not** have to be on the same node.

It only needs to be in the same zone.

---

# 17. Think of Topology as Levels

A useful teaching model is:

```text
Cluster
   |
   +-------------------------+
   |                         |
 Zone-A                    Zone-B
   |                         |
   +--------+--------+        +--------+--------+
   |        |        |        |        |        |
 Node-1   Node-2   Node-3   Node-4   Node-5   Node-6
```

Different topology keys define different boundaries.

```text
hostname
   ↓
Node-level relationship
```

```text
zone
   ↓
Zone-level relationship
```

The scheduler uses the topology label to determine which nodes belong to the same topology domain.

---

# 18. Hard vs Soft Affinity

Pod affinity has two major forms.

## Hard Affinity

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
```

Meaning:

```text
MUST satisfy
```

If no suitable location exists:

```text
Pod
 ↓
Pending
```

---

## Soft Affinity

```yaml
preferredDuringSchedulingIgnoredDuringExecution:
```

Meaning:

```text
TRY to satisfy
```

If Kubernetes cannot satisfy the preference, it can still schedule the Pod elsewhere.

---

# 19. Soft Affinity Example

```yaml
affinity:

  podAffinity:

    preferredDuringSchedulingIgnoredDuringExecution:

      - weight: 100

        podAffinityTerm:

          labelSelector:

            matchLabels:
              app: backend

          topologyKey: kubernetes.io/hostname
```

Teaching interpretation:

```text
"I would LIKE to be on the same node
 as backend Pods."

NOT:

"I MUST be on the same node."
```

---

# 20. Important Syntax Difference

### Required

```yaml
requiredDuringSchedulingIgnoredDuringExecution:

  - labelSelector:
      matchLabels:
        app: backend

    topologyKey: kubernetes.io/hostname
```

### Preferred

```yaml
preferredDuringSchedulingIgnoredDuringExecution:

  - weight: 100

    podAffinityTerm:
      labelSelector:
        matchLabels:
          app: backend

      topologyKey: kubernetes.io/hostname
```

Notice that the soft rule uses:

```yaml
podAffinityTerm:
```

and also requires:

```yaml
weight:
```

---

# 21. Useful Verification Commands

Get all Pods:

```bash
kubectl get pods -n affinity-demo -o wide
```

Get labels:

```bash
kubectl get pods -n affinity-demo --show-labels
```

Get nodes and topology labels:

```bash
kubectl get nodes \
  -L kubernetes.io/hostname \
  -L topology.kubernetes.io/zone
```

Describe a Pod:

```bash
kubectl describe pod <frontend-pod> -n affinity-demo
```

Look at scheduler events:

```bash
kubectl get events \
  -n affinity-demo \
  --sort-by=.lastTimestamp
```

---

# 22. Teaching Exercise — Make the Rule Fail

This is an excellent classroom demonstration.

Temporarily change:

```yaml
values:
  - backend
```

to a label that does not exist:

```yaml
values:
  - does-not-exist
```

Because the rule is:

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
```

the scheduler cannot find a matching Pod.

Apply the change:

```bash
kubectl apply -f 03-frontend-affinity.yaml
```

Then:

```bash
kubectl get pods -n affinity-demo -o wide
```

You should see the affected Pod remain:

```text
Pending
```

Now inspect it:

```bash
kubectl describe pod <pending-pod> -n affinity-demo
```

Look at the scheduler events.

This demonstrates:

```text
required
   +
no matching topology domain
   =
Pod cannot be scheduled
```

---

# 23. Teaching Exercise — Fix the Rule

Restore:

```yaml
values:
  - backend
```

Apply:

```bash
kubectl apply -f 03-frontend-affinity.yaml
```

Watch:

```bash
kubectl get pods -n affinity-demo -o wide -w
```

Once the matching backend Pods are available, the scheduler can satisfy the affinity rule.

---

# 24. Order of Execution for Teaching

Use this exact order during the classroom demo.

```text
1. Explain topologyKey
        |
        v
2. Show node topology labels
        |
        v
3. Create namespace
        |
        v
4. Create backend Deployment
        |
        v
5. Verify backend Pods
        |
        v
6. Show backend labels
        |
        v
7. Create frontend Deployment
        |
        v
8. Explain labelSelector
        |
        v
9. Explain topologyKey
        |
        v
10. Verify frontend placement
        |
        v
11. Change hostname → zone
        |
        v
12. Compare scheduling behavior
        |
        v
13. Demonstrate required vs preferred
        |
        v
14. Intentionally break the selector
        |
        v
15. Observe Pending Pod
        |
        v
16. Fix the selector
        |
        v
17. Clean up
```

---

# 25. One-Minute Explanation for Students

You can explain it like this:

> **Pod affinity tells Kubernetes that a Pod wants to be close to another Pod.**
>
> The `labelSelector` tells Kubernetes **which Pods** we care about.
>
> The `topologyKey` tells Kubernetes **what "close" means**.
>
> With `kubernetes.io/hostname`, close means **same node**.
>
> With `topology.kubernetes.io/zone`, close means **same zone**.
>
> `requiredDuringSchedulingIgnoredDuringExecution` makes the rule mandatory during scheduling.
>
> `preferredDuringSchedulingIgnoredDuringExecution` makes it a preference.

---

# 26. Mental Model

Remember this formula:

```text
Pod Affinity
     =
WHO should I be close to?
     +
WHERE should "close" be?
```

Where:

```text
labelSelector
      =
WHO
```

and:

```text
topologyKey
      =
WHERE / WHAT TOPOLOGY LEVEL
```

So:

```yaml
labelSelector:
  app: backend

topologyKey:
  kubernetes.io/hostname
```

means:

```text
"Find backend Pods
 and be on the same node."
```

Whereas:

```yaml
labelSelector:
  app: backend

topologyKey:
  topology.kubernetes.io/zone
```

means:

```text
"Find backend Pods
 and be in the same zone."
```

---

# 27. Cleanup

Delete the demo namespace:

```bash
kubectl delete namespace affinity-demo
```

Verify:

```bash
kubectl get namespaces
```

---

# 28. Final Takeaway

```text
                 topologyKey
                      |
          +-----------+-----------+
          |                       |
          v                       v
     hostname                    zone
          |                       |
          v                       v
      SAME NODE                SAME ZONE
```

### The key sentence to remember:

> **`topologyKey` defines what counts as "together."**

And:

```text
Pod Affinity
     ↓
Co-locate workloads
     ↓
labelSelector = which Pods?
     ↓
topologyKey = together at what level?
```

That is the core idea behind Kubernetes Pod Affinity.
