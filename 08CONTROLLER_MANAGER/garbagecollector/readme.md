# Kubernetes Garbage Collector Demo

## Overview

This practical demonstrates how the **Kubernetes Garbage Collector (GC)** automatically removes resources whose owner has been deleted.

The demo uses:

```text
Deployment
    │
    ▼
ReplicaSet
    │
    ▼
Pods
```

Kubernetes maintains this relationship using **`ownerReferences`**.

When the Deployment is deleted, Kubernetes can automatically garbage-collect its dependent ReplicaSet and Pods.

---

## Learning Objectives

By completing this demo, you will understand:

* What Kubernetes Garbage Collector is
* Why Garbage Collection is required
* What `ownerReferences` are
* How Kubernetes establishes parent-child relationships
* How Deployment → ReplicaSet → Pod ownership works
* Background cascading deletion
* Foreground cascading deletion
* Orphan deletion
* Difference between Controllers and Garbage Collector
* How to inspect ownership using `kubectl`

---

# 1. Prerequisites

A running Kubernetes cluster.

Verify:

```bash
kubectl get nodes
```

Expected:

```text
NAME           STATUS   ROLES           AGE
controlplane   Ready    control-plane   ...
worker         Ready    <none>          ...
```

---

# 2. Create Demo Namespace

```bash
kubectl create namespace gc-demo
```

Verify:

```bash
kubectl get namespace gc-demo
```

---

# 3. Create Deployment

Create the file:

```bash
nano deployment.yaml
```

Add:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gc-demo
  namespace: gc-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: gc-demo
  template:
    metadata:
      labels:
        app: gc-demo
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

# 4. Verify Resources

Run:

```bash
kubectl get all -n gc-demo
```

You should see:

```text
NAME                           READY   STATUS    RESTARTS   AGE
pod/gc-demo-xxxxxxxxxx-xxxxx   1/1     Running   0          10s
pod/gc-demo-xxxxxxxxxx-yyyyy   1/1     Running   0          10s
pod/gc-demo-xxxxxxxxxx-zzzzz   1/1     Running   0          10s

NAME                      READY   UP-TO-DATE   AVAILABLE
deployment.apps/gc-demo   3/3     3            3

NAME                                 DESIRED   CURRENT   READY
replicaset.apps/gc-demo-xxxxxxxxxx   3         3         3
```

The hierarchy is:

```text
Deployment
     │
     │ owns
     ▼
ReplicaSet
     │
     │ owns
     ▼
Pods
```

---

# 5. Understand ownerReferences

The most important concept in this demo is:

```yaml
ownerReferences:
```

Kubernetes uses `ownerReferences` to establish ownership between objects.

Check the ReplicaSet:

```bash
kubectl get rs -n gc-demo -o yaml
```

Look for:

```yaml
ownerReferences:
- apiVersion: apps/v1
  blockOwnerDeletion: true
  controller: true
  kind: Deployment
  name: gc-demo
  uid: ...
```

This means:

```text
ReplicaSet
     │
     └── owned by ──► Deployment/gc-demo
```

---

# 6. Check Pod Ownership

Run:

```bash
kubectl get pods -n gc-demo -o yaml
```

Look for:

```yaml
ownerReferences:
- apiVersion: apps/v1
  kind: ReplicaSet
  name: gc-demo-xxxxxxxxxx
  uid: ...
```

Therefore:

```text
Deployment
    │
    │ ownerReference
    ▼
ReplicaSet
    │
    │ ownerReference
    ▼
Pod
```

This ownership chain is what allows Kubernetes Garbage Collector to identify dependent resources.

---

# 7. Display Ownership More Clearly

For ReplicaSet:

```bash
kubectl get rs -n gc-demo \
-o custom-columns="NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name"
```

Example:

```text
NAME                     OWNER
gc-demo-7d8c9f8b7d       gc-demo
```

For Pods:

```bash
kubectl get pods -n gc-demo \
-o custom-columns="NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name"
```

Example:

```text
NAME                          OWNER
gc-demo-7d8c9f8b7d-abc12      gc-demo-7d8c9f8b7d
gc-demo-7d8c9f8b7d-def34      gc-demo-7d8c9f8b7d
gc-demo-7d8c9f8b7d-ghi56      gc-demo-7d8c9f8b7d
```

---

# 8. Garbage Collection Demo

Open Terminal 1:

```bash
kubectl get all -n gc-demo -w
```

This continuously watches the resources.

Open Terminal 2 and delete the Deployment:

```bash
kubectl delete deployment gc-demo -n gc-demo
```

The Deployment is deleted.

Kubernetes Garbage Collector detects:

```text
Deployment deleted
       │
       ▼
Find objects owned by Deployment
       │
       ▼
ReplicaSet found
       │
       ▼
ReplicaSet deleted
       │
       ▼
Find objects owned by ReplicaSet
       │
       ▼
Pods found
       │
       ▼
Pods deleted
```

Verify:

```bash
kubectl get all -n gc-demo
```

Eventually:

```text
No resources found in gc-demo namespace.
```

---

# 9. What Actually Deleted the Resources?

Important teaching point:

The command:

```bash
kubectl delete deployment gc-demo
```

does **not** mean that kubectl individually deletes:

```text
Deployment
ReplicaSet
Pod
Pod
Pod
```

Instead:

```text
kubectl
   │
   ▼
API Server
   │
   ▼
Deployment deleted
   │
   ▼
Garbage Collector
   │
   ▼
Checks ownerReferences
   │
   ├── ReplicaSet
   │
   └── dependent resources
```

The Garbage Collector performs the dependent-resource cleanup.

---

# 10. Cascading Deletion

Kubernetes supports cascading deletion.

There are three important behaviors:

```text
background
foreground
orphan
```

---

# 11. Background Deletion

Recreate the Deployment:

```bash
kubectl apply -f deployment.yaml
```

Delete using:

```bash
kubectl delete deployment gc-demo \
  -n gc-demo \
  --cascade=background
```

Conceptually:

```text
Delete Deployment
       │
       ▼
Deployment removed
       │
       ▼
Garbage Collector works
asynchronously
       │
       ├── ReplicaSet
       └── Pods
```

The owner can disappear before all dependents have finished deleting.

---

# 12. Foreground Deletion

Recreate:

```bash
kubectl apply -f deployment.yaml
```

Delete:

```bash
kubectl delete deployment gc-demo \
  -n gc-demo \
  --cascade=foreground
```

Conceptually:

```text
Deployment deletion requested
          │
          ▼
Dependents must be removed
          │
          ├── ReplicaSet
          │
          └── Pods
          │
          ▼
Owner completely deleted
```

Foreground deletion waits for dependent resources to be removed before completing the owner's deletion.

---

# 13. Orphan Deletion

Recreate:

```bash
kubectl apply -f deployment.yaml
```

Verify:

```bash
kubectl get all -n gc-demo
```

Now run:

```bash
kubectl delete deployment gc-demo \
  -n gc-demo \
  --cascade=orphan
```

Check:

```bash
kubectl get all -n gc-demo
```

You may still see:

```text
ReplicaSet
Pods
```

Why?

Because the dependents are being **orphaned** instead of garbage-collected.

Conceptually:

```text
Deployment ❌
     │
     X
     │
     ▼
ReplicaSet
     │
     ▼
Pods
```

The ownership relationship is removed.

---

# 14. Compare Deletion Strategies

| Strategy   | Owner               | Dependents                |
| ---------- | ------------------- | ------------------------- |
| Background | Deleted immediately | GC deletes asynchronously |
| Foreground | Deletion waits      | Dependents deleted first  |
| Orphan     | Deleted             | Dependents remain         |

Commands:

```bash
--cascade=background
```

```bash
--cascade=foreground
```

```bash
--cascade=orphan
```

---

# 15. Garbage Collector vs Controller

This is an important interview and teaching concept.

## Deployment Controller

The Deployment Controller maintains the desired state.

For example:

```text
Deployment
replicas = 3
     │
     ▼
ReplicaSet
     │
     ├── Pod
     ├── Pod
     └── Pod
```

If one Pod crashes:

```text
Pod ❌
 │
 ▼
ReplicaSet Controller
 │
 ▼
Creates replacement Pod
```

---

## Garbage Collector

The Garbage Collector handles cleanup.

Example:

```text
Deployment deleted
       │
       ▼
Garbage Collector
       │
       ▼
Checks ownerReferences
       │
       ▼
ReplicaSet
       │
       ▼
Pods
       │
       ▼
Cleanup
```

### Simple distinction

```text
Controller
= Maintains desired state

Garbage Collector
= Cleans up dependent resources
```

---

# 16. Complete Architecture

```text
                    Kubernetes API Server
                            │
             ┌──────────────┴──────────────┐
             │                             │
             ▼                             ▼
    Deployment Controller          Garbage Collector
             │                             │
             ▼                             │
        ReplicaSet                        │
             │                            │
             ▼                            │
            Pods ◄────────────────────────┘
                         ownerReferences
```

The Deployment Controller creates and manages resources.

The Garbage Collector understands:

```text
WHO OWNS WHOM?
```

using:

```yaml
ownerReferences:
```

---

# 17. Complete Practical Flow

Run the following commands in sequence.

### Step 1 — Create namespace

```bash
kubectl create namespace gc-demo
```

### Step 2 — Deploy application

```bash
kubectl apply -f deployment.yaml
```

### Step 3 — Verify

```bash
kubectl get all -n gc-demo
```

### Step 4 — Inspect ReplicaSet ownership

```bash
kubectl get rs -n gc-demo -o yaml
```

### Step 5 — Inspect Pod ownership

```bash
kubectl get pods -n gc-demo -o yaml
```

### Step 6 — Watch resources

```bash
kubectl get all -n gc-demo -w
```

### Step 7 — Delete Deployment

```bash
kubectl delete deployment gc-demo -n gc-demo
```

### Step 8 — Verify cleanup

```bash
kubectl get all -n gc-demo
```

---

# 18. Useful Troubleshooting Commands

List deployments:

```bash
kubectl get deployments -n gc-demo
```

List ReplicaSets:

```bash
kubectl get rs -n gc-demo
```

List Pods:

```bash
kubectl get pods -n gc-demo
```

Inspect Deployment:

```bash
kubectl describe deployment gc-demo -n gc-demo
```

Inspect ReplicaSet:

```bash
kubectl describe rs -n gc-demo
```

Inspect Pod:

```bash
kubectl describe pod <pod-name> -n gc-demo
```

Inspect raw ownership:

```bash
kubectl get deployment gc-demo -n gc-demo -o yaml
```

```bash
kubectl get rs -n gc-demo -o yaml
```

```bash
kubectl get pods -n gc-demo -o yaml
```

---

# 19. Cleanup

If any resources remain:

```bash
kubectl delete namespace gc-demo
```

Verify:

```bash
kubectl get namespace gc-demo
```

Expected:

```text
Error from server (NotFound):
namespaces "gc-demo" not found
```

---

# 20. Interview Questions

### Q1. What is Kubernetes Garbage Collector?

Kubernetes Garbage Collector is a control-plane mechanism that removes dependent resources when their owner is deleted, based on `ownerReferences`.

### Q2. What is ownerReference?

`ownerReference` identifies the Kubernetes object that owns another object.

Example:

```text
ReplicaSet
    │
    └── ownerReference → Deployment
```

### Q3. Who creates the ReplicaSet for a Deployment?

The **Deployment Controller**.

### Q4. Who cleans up the ReplicaSet when the Deployment is deleted?

The **Garbage Collector**.

### Q5. What happens to Pods when their ReplicaSet is deleted?

If the Pods are owned by that ReplicaSet, the Garbage Collector can delete them as dependents.

### Q6. What is `--cascade=orphan`?

It deletes the owner while keeping its dependent resources.

### Q7. What is foreground deletion?

Dependent resources are deleted first, and completion of the owner's deletion waits for them.

### Q8. What is background deletion?

The owner is deleted and dependent cleanup happens asynchronously.

---

# 21. Final Mental Model

Remember:

```text
              OWNER
                │
                │ ownerReferences
                ▼
            DEPENDENT
                │
                │ ownerReferences
                ▼
            DEPENDENT
```

When the owner disappears:

```text
          OWNER ❌
             │
             ▼
     Garbage Collector
             │
             ▼
    Check ownerReferences
             │
             ▼
       Find dependents
             │
             ▼
        Delete them
```

### Golden Rule

> **Controllers maintain resources; Garbage Collector cleans up resources that have lost their owners.**

---

## Suggested Classroom Demo

The strongest teaching sequence is:

```text
1. Create Deployment
        ↓
2. Show Deployment
        ↓
3. Show ReplicaSet
        ↓
4. Show Pods
        ↓
5. Show ownerReferences
        ↓
6. Delete Deployment
        ↓
7. Watch ReplicaSet disappear
        ↓
8. Watch Pods disappear
        ↓
9. Repeat with --cascade=foreground
        ↓
10. Repeat with --cascade=orphan
        ↓
11. Compare all 3 behaviors
```

This demonstrates both **how Garbage Collection works internally** and **how cascading deletion changes its behavior**.
