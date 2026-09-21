Absolutely. Below is a **teaching-focused** **`README.md`** that compares:

- `kubectl scale` vs changing replicas in YAML 
- `kubectl edit` vs editing YAML 
-  Imperative vs Declarative approach 
-  Deployment and ReplicaSet examples 
-  What happens to the live cluster vs configuration file 
-  Recommended practical workflow 

```
```

````
# Kubernetes – Imperative vs Declarative Management

## 📌 Objective

Understand the difference between managing Kubernetes resources using:

1. `kubectl scale`
2. `kubectl edit`
3. YAML file modification
4. `kubectl apply`

The main concept is:

> **Imperative commands directly modify the live Kubernetes object.**

> **Declarative YAML defines the desired state, and `kubectl apply` makes the cluster match that state.**

---

# 1. Imperative vs Declarative

| Approach | Example | What happens? |
|---|---|---|
| Imperative | `kubectl scale` | Directly changes the live object |
| Imperative | `kubectl edit` | Directly edits the live object |
| Declarative | Edit YAML + `kubectl apply` | YAML becomes the desired state |
| Declarative | `kubectl apply -f file.yaml` | Kubernetes reconciles actual state with desired state |

### Simple understanding

```text
IMPERATIVE

Command
   ↓
Live Kubernetes Object
   ↓
Controller
   ↓
Pods
````

Example:

```
```

```
kubectl scale deployment nginx --replicas=5
```

---

```
```

```
DECLARATIVE

YAML File
   ↓
kubectl apply
   ↓
API Server
   ↓
Desired State
   ↓
Controller
   ↓
Pods
```

Example:

```
```

```
kubectl apply -f deployment.yaml
```

---

# 2. Example 1 – Deployment

Create a file:

```
```

```
deployment.yaml
```

```
```

```
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nginx-deployment

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
          image: nginx:1.27
          ports:
            - containerPort: 80
```

---

# 3. Create the Deployment

```
```

```
kubectl apply -f deployment.yaml
```

Check:

```
```

```
kubectl get deployment
```

Expected:

```
```

```
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   3/3     3            3           ...
```

Check Pods:

```
```

```
kubectl get pods
```

Expected:

```
```

```
nginx-deployment-xxxxx   Running
nginx-deployment-yyyyy   Running
nginx-deployment-zzzzz   Running
```

---

# 4. Scaling Using `kubectl scale`

Suppose the Deployment currently has:

```
```

```
replicas: 3
```

Run:

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

Check:

```
```

```
kubectl get deployment
```

Now:

```
```

```
READY
5/5
```

Check Pods:

```
```

```
kubectl get pods
```

There will now be 5 Pods.

---

# 5. Important Point – What Happened to YAML?

The command:

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

changed the **live Kubernetes object**.

It did NOT automatically change:

```
```

```
deployment.yaml
```

Your file still contains:

```
```

```
replicas: 3
```

But the live Deployment contains:

```
```

```
replicas: 5
```

Therefore:

```
```

```
YAML FILE
replicas: 3
     │
     │
     │  kubectl scale
     ↓
LIVE OBJECT
replicas: 5
```

---

# 6. The Important Problem

Suppose you now run:

```
```

```
kubectl apply -f deployment.yaml
```

Your YAML says:

```
```

```
replicas: 3
```

Therefore Kubernetes will reconcile the Deployment back to:

```
```

```
3 replicas
```

The Pods will scale:

```
```

```
5 Pods
  ↓
3 Pods
```

This demonstrates an important concept:

> The YAML file represents the desired configuration you are applying.

---

# 7. Recommended Declarative Scaling

Instead of:

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

modify:

```
```

```
replicas: 3
```

to:

```
```

```
replicas: 5
```

Then:

```
```

```
kubectl apply -f deployment.yaml
```

Now:

```
```

```
deployment.yaml
replicas: 5
       ↓
kubectl apply
       ↓
Deployment
       ↓
5 Pods
```

The configuration file and live object remain aligned.

---

# 8. `kubectl scale` vs YAML Scaling

## Method 1 – Imperative

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

### Advantage

Fast and convenient.

### Disadvantage

The YAML file does not automatically change.

---

## Method 2 – Declarative

Change:

```
```

```
replicas: 5
```

Then:

```
```

```
kubectl apply -f deployment.yaml
```

### Advantage

The configuration is stored in the YAML file.

### Advantage

Easy to reproduce.

### Advantage

Works well with Git and CI/CD.

---

# 9. Scaling Down

Current state:

```
```

```
replicas: 5
```

Scale down to 2.

### Imperative

```
```

```
kubectl scale deployment nginx-deployment --replicas=2
```

Live state becomes:

```
```

```
2 Pods
```

But YAML may still contain:

```
```

```
replicas: 5
```

---

### Declarative

Change YAML:

```
```

```
replicas: 2
```

Then:

```
```

```
kubectl apply -f deployment.yaml
```

Now:

```
```

```
YAML
replicas: 2
   ↓
Deployment
   ↓
2 Pods
```

---

# 10. `kubectl edit`

Another way to modify a live resource is:

```
```

```
kubectl edit deployment nginx-deployment
```

Kubernetes opens the live Deployment definition in an editor.

Find:

```
```

```
spec:
  replicas: 3
```

Change it to:

```
```

```
spec:
  replicas: 5
```

Save and exit.

Kubernetes immediately updates the live Deployment.

---

# 11. Important Difference – `kubectl edit`

When you run:

```
```

```
kubectl edit deployment nginx-deployment
```

you are editing:

```
```

```
LIVE OBJECT
```

You are NOT editing:

```
```

```
deployment.yaml
```

Therefore:

```
```

```
deployment.yaml
replicas: 3

        ❌

LIVE DEPLOYMENT
replicas: 5
```

The two can become different.

---

# 12. YAML Editing

With the declarative method:

```
```

```
vi deployment.yaml
```

Change:

```
```

```
replicas: 3
```

to:

```
```

```
replicas: 5
```

Then:

```
```

```
kubectl apply -f deployment.yaml
```

Now:

```
```

```
YAML
replicas: 5
      ↓
kubectl apply
      ↓
LIVE DEPLOYMENT
replicas: 5
```

Both represent the same desired configuration.

---

# 13. `kubectl edit` vs YAML Editing

| Feature`kubectl edit`Edit YAML           |            |                 |
| ---------------------------------------- | ---------- | --------------- |
| Modifies live object                     | ✅          | Through `apply` |
| Modifies local YAML                      | ❌          | ✅               |
| Good for quick troubleshooting           | ✅          | ✅               |
| Configuration stored as code             | ❌          | ✅               |
| Git friendly                             | ❌          | ✅               |
| Reproducible                             | Limited    | ✅               |
| Recommended for production configuration | Usually no | ✅               |

---

# 14. ReplicaSet Example

Create:

```
```

```
replicaset.yaml
```

```
```

```
apiVersion: apps/v1
kind: ReplicaSet

metadata:
  name: nginx-rs

spec:
  replicas: 3

  selector:
    matchLabels:
      app: nginx-rs

  template:
    metadata:
      labels:
        app: nginx-rs

    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
```

---

# 15. Create ReplicaSet

```
```

```
kubectl apply -f replicaset.yaml
```

Check:

```
```

```
kubectl get rs
```

Expected:

```
```

```
NAME       DESIRED   CURRENT   READY
nginx-rs   3         3         3
```

Check Pods:

```
```

```
kubectl get pods
```

---

# 16. Scale ReplicaSet Using Command

```
```

```
kubectl scale rs nginx-rs --replicas=5
```

Check:

```
```

```
kubectl get rs
```

Now:

```
```

```
DESIRED   CURRENT   READY
5         5         5
```

But:

```
```

```
replicas: 3
```

still exists in:

```
```

```
replicaset.yaml
```

---

# 17. Scale ReplicaSet Using YAML

Change:

```
```

```
replicas: 3
```

to:

```
```

```
replicas: 5
```

Then:

```
```

```
kubectl apply -f replicaset.yaml
```

The ReplicaSet becomes:

```
```

```
5 replicas
```

---

# 18. `kubectl edit` ReplicaSet

You can also run:

```
```

```
kubectl edit rs nginx-rs
```

Find:

```
```

```
spec:
  replicas: 3
```

Change:

```
```

```
spec:
  replicas: 5
```

Save and exit.

The live ReplicaSet will now have:

```
```

```
5 replicas
```

But:

```
```

```
replicaset.yaml
```

may still say:

```
```

```
replicas: 3
```

---

# 19. Complete Comparison

| TaskImperative CommandDeclarative YAML |                                                          |                                        |
| -------------------------------------- | -------------------------------------------------------- | -------------------------------------- |
| Scale Deployment                       | `kubectl scale deployment nginx-deployment --replicas=5` | Change `replicas: 5` + `kubectl apply` |
| Scale ReplicaSet                       | `kubectl scale rs nginx-rs --replicas=5`                 | Change `replicas: 5` + `kubectl apply` |
| Edit live Deployment                   | `kubectl edit deployment nginx-deployment`               | Edit YAML + `kubectl apply`            |
| Edit live ReplicaSet                   | `kubectl edit rs nginx-rs`                               | Edit YAML + `kubectl apply`            |
| Changes YAML file?                     | ❌                                                        | ✅                                      |
| Changes live object?                   | ✅                                                        | ✅                                      |
| GitOps friendly                        | ❌                                                        | ✅                                      |
| Reproducible                           | ❌/Limited                                                | ✅                                      |
| Quick temporary change                 | ✅                                                        | ✅                                      |

---

# 20. Very Important Concept

## `kubectl scale`

```
```

```
Command
   ↓
Live Object
```

It is primarily a **quick imperative change**.

---

## `kubectl edit`

```
```

```
kubectl edit
      ↓
Live Object
```

It directly modifies the resource stored in the Kubernetes API.

---

## YAML + `kubectl apply`

```
```

```
YAML
 ↓
kubectl apply
 ↓
API Server
 ↓
Desired State
 ↓
Controller
 ↓
Actual State
```

This is the **declarative model**.

---

# 21. Why YAML Is Preferred for Production

Suppose you have:

```
```

```
replicas: 5
image: nginx:1.27
```

This configuration can be stored in Git.

Example:

```
```

```
Git Repository
      │
      ├── deployment.yaml
      ├── replicaset.yaml
      └── service.yaml
```

Anyone can reproduce the environment:

```
```

```
kubectl apply -f deployment.yaml
```

---

# 22. GitOps Concept

Declarative YAML is especially important for GitOps.

```
```

```
Git Repository
      │
      │ YAML
      ↓
Desired State
      │
      ↓
Kubernetes
      │
      ↓
Actual State
```

Tools such as Argo CD can continuously compare:

```
```

```
Git Desired State
        VS
Cluster Live State
```

and reconcile differences.

---

# 23. Practical Demonstration

## Step 1 – Create Deployment

```
```

```
kubectl apply -f deployment.yaml
```

Check:

```
```

```
kubectl get deploy
kubectl get pods
```

---

## Step 2 – Scale Imperatively

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

Check:

```
```

```
kubectl get pods
```

You should see 5 Pods.

Now check YAML:

```
```

```
cat deployment.yaml
```

It still says:

```
```

```
replicas: 3
```

---

## Step 3 – Apply YAML Again

```
```

```
kubectl apply -f deployment.yaml
```

Check:

```
```

```
kubectl get pods
```

The Deployment will reconcile to:

```
```

```
3 Pods
```

---

## Step 4 – Change YAML

Edit:

```
```

```
vi deployment.yaml
```

Change:

```
```

```
replicas: 3
```

to:

```
```

```
replicas: 5
```

Apply:

```
```

```
kubectl apply -f deployment.yaml
```

Check:

```
```

```
kubectl get pods
```

Now:

```
```

```
5 Pods
```

---

# 24. Demonstrate `kubectl edit`

Run:

```
```

```
kubectl edit deployment nginx-deployment
```

Change:

```
```

```
replicas: 5
```

to:

```
```

```
replicas: 2
```

Save and exit.

Check:

```
```

```
kubectl get pods
```

Now:

```
```

```
2 Pods
```

But check:

```
```

```
cat deployment.yaml
```

The file may still contain:

```
```

```
replicas: 5
```

This creates configuration drift.

---

# 25. Configuration Drift

Configuration drift occurs when:

```
```

```
YAML Configuration
        ≠
Live Kubernetes Configuration
```

Example:

```
```

```
deployment.yaml

replicas: 5
      │
      │
      ❌ DIFFERENT
      │
      ↓
Live Deployment

replicas: 2
```

This can cause unexpected changes when the YAML is applied again.

---

# 26. Production Recommendation

### For quick testing

Use:

```
```

```
kubectl scale
```

or:

```
```

```
kubectl edit
```

Example:

```
```

```
kubectl scale deployment nginx-deployment --replicas=10
```

---

### For persistent configuration

Prefer:

```
```

```
Edit YAML
   ↓
Review
   ↓
Git commit
   ↓
kubectl apply
```

Example:

```
```

```
vi deployment.yaml

kubectl apply -f deployment.yaml
```

---

# 27. Golden Rule

> **If you want the change to become part of your configuration, change the YAML.**

> **If you want a quick live change, use an imperative command.**

---

# 28. Deployment vs ReplicaSet

A Deployment normally manages a ReplicaSet.

```
```

```
Deployment
     │
     ↓
ReplicaSet
     │
     ↓
Pods
```

Therefore, in normal application management:

```
```

```
Deployment YAML
      ↓
Deployment
      ↓
ReplicaSet
      ↓
Pods
```

You normally scale the **Deployment**, not the ReplicaSet directly.

Example:

```
```

```
kubectl scale deployment nginx-deployment --replicas=5
```

The Deployment will manage the ReplicaSet accordingly.

A standalone ReplicaSet is useful for understanding the underlying Kubernetes controller behavior.

---

# 29. Quick Revision

```
```

```
kubectl scale
     ↓
Imperative
     ↓
Changes LIVE object
     ↓
Does NOT update local YAML
```

```
```

```
kubectl edit
     ↓
Imperative
     ↓
Edits LIVE object
     ↓
Does NOT update local YAML
```

```
```

```
Edit YAML
     ↓
Declarative
     ↓
kubectl apply
     ↓
Changes LIVE object
     ↓
Configuration is stored in YAML
```

---

# 30. Final Mental Model

```
```

```
                 KUBERNETES

       ┌─────────────────────────┐
       │       YAML FILE         │
       │                         │
       │ replicas: 5             │
       │ image: nginx:1.27       │
       └────────────┬────────────┘
                    │
                    │ kubectl apply
                    ↓
       ┌─────────────────────────┐
       │      API SERVER         │
       │                         │
       │     Desired State       │
       └────────────┬────────────┘
                    │
                    ↓
              Controller
                    │
                    ↓
               ReplicaSet
                    │
                    ↓
                  Pods


Imperative path:

kubectl scale / kubectl edit
             │
             ↓
        API Server
             │
             ↓
        Live Object
```

## ⭐ Key Takeaway

```
```

```
IMPERATIVE

"Do this now."

kubectl scale
kubectl edit
```

```
```

```
DECLARATIVE

"This is how I want the system to look."

YAML
+
kubectl apply
```

For production and GitOps-style Kubernetes management, keeping the desired configuration in YAML provides a reproducible source of truth.

```
```

````

### Suggested practical structure

Keep these three files together for your lab:

```text
kubernetes-scale-edit-demo/
│
├── README.md
├── deployment.yaml
└── replicaset.yaml
````

The **Deployment YAML should be the main practical**, while the ReplicaSet YAML can demonstrate what happens underneath and how direct ReplicaSet scaling differs from normal Deployment management.
