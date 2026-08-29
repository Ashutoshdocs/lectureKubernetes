# Kubernetes Admission Controllers Demo

## Overview

This demo explains and demonstrates the two major types of Kubernetes admission control:

```text
                    Admission Controllers
                           │
              ┌────────────┴────────────┐
              │                         │
          Mutating                  Validating
              │                         │
        Modify request             Check request
              │                         │
              ▼                         ▼
       Change the object          Allow or Reject
```

### Two Types

| Type | Purpose | Can Modify Object? | Can Reject Request? |
|---|---|---:|---:|
| **Mutating** | Modify the incoming request | ✅ Yes | Not its primary role |
| **Validating** | Validate the request | ❌ No | ✅ Yes |

In this lab:

- **MutatingAdmissionPolicy** automatically adds a label to Pods.
- **ValidatingAdmissionPolicy** rejects Pods that do not contain a required label.

> **Prerequisite:** This lab uses `MutatingAdmissionPolicy` and `ValidatingAdmissionPolicy`, which require a Kubernetes version that supports these APIs. Check your cluster before starting.

---

# 1. Admission Control Request Flow

When a user creates a Kubernetes object:

```text
kubectl apply
     │
     ▼
┌─────────────────┐
│    API Server   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────┐
│     Admission Control       │
│                             │
│   ┌─────────────────────┐   │
│   │ Mutating            │   │
│   │                     │   │
│   │ Modify request      │   │
│   └──────────┬──────────┘   │
│              │              │
│              ▼              │
│   ┌─────────────────────┐   │
│   │ Validating          │   │
│   │                     │   │
│   │ Check request       │   │
│   └──────────┬──────────┘   │
└──────────────┼──────────────┘
               │
         ┌─────┴─────┐
         │           │
       ALLOW        DENY
         │
         ▼
       etcd
```

The important concept is:

```text
Mutating
   ↓
Modify

Validating
   ↓
Validate
```

---

# 2. Lab Environment

You need:

```text
Kubernetes Cluster
kubectl
```

Check the cluster:

```bash
kubectl cluster-info
```

Check Kubernetes version:

```bash
kubectl version
```

Check whether the APIs are available:

```bash
kubectl api-resources | grep -i admission
```

You can also check:

```bash
kubectl explain mutatingadmissionpolicy
kubectl explain validatingadmissionpolicy
```

If these resources are unavailable, this particular demo cannot be run on that cluster.

---

# 3. Demo 1 — Mutating Admission Controller

## Objective

We will create a mutating admission policy that automatically adds:

```text
admission=mutated
```

to every newly created Pod.

The user will create a Pod **without the label**.

The admission policy will modify the Pod before it is persisted.

---

# 4. Create the Mutating Policy

Create the file:

```bash
vim mutating-policy.yaml
```

Add:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: add-admission-label
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]

  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >
          Object{
            metadata: Object.metadata{
              labels: map[string]string{
                "admission": "mutated"
              }
            }
          }
```

Apply:

```bash
kubectl apply -f mutating-policy.yaml
```

Check:

```bash
kubectl get mutatingadmissionpolicy
```

Expected:

```text
NAME
add-admission-label
```

---

# 5. Create the Mutating Policy Binding

The policy must be bound before it becomes active.

Create:

```bash
vim mutating-binding.yaml
```

Add:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: add-admission-label-binding
spec:
  policyName: add-admission-label
```

Apply:

```bash
kubectl apply -f mutating-binding.yaml
```

Check:

```bash
kubectl get mutatingadmissionpolicybinding
```

Expected:

```text
NAME
add-admission-label-binding
```

---

# 6. Create a Pod Without the Label

Create:

```bash
vim nginx.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-mutating-demo
spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Notice that there is **no**:

```yaml
labels:
  admission: mutated
```

Create the Pod:

```bash
kubectl apply -f nginx.yaml
```

Expected:

```text
pod/nginx-mutating-demo created
```

---

# 7. Verify the Mutation

Run:

```bash
kubectl get pod nginx-mutating-demo --show-labels
```

You should see:

```text
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
nginx-mutating-demo    1/1     Running   0          ...   admission=mutated
```

The label was added automatically.

Check the complete object:

```bash
kubectl get pod nginx-mutating-demo -o yaml
```

Look for:

```yaml
metadata:
  labels:
    admission: mutated
```

---

# 8. What Happened?

The user submitted:

```yaml
metadata:
  name: nginx-mutating-demo
```

The Mutating Admission Controller changed it to:

```yaml
metadata:
  name: nginx-mutating-demo
  labels:
    admission: mutated
```

Conceptually:

```text
User
 │
 │ Pod without label
 ▼
API Server
 │
 ▼
Mutating Admission Policy
 │
 │ Adds admission=mutated
 ▼
Modified Pod
 │
 ▼
Validation / remaining admission processing
 │
 ▼
Persisted object
```

### Key Point

> **Mutating admission controllers modify Kubernetes API requests before the object is persisted.**

---

# 9. Demo 2 — Validating Admission Controller

## Objective

Now we will create a validating admission policy.

The policy will require every newly created Pod to have:

```text
team=<value>
```

For example:

```yaml
labels:
  team: devops
```

A Pod without the `team` label will be rejected.

---

# 10. Create the Validating Policy

Create:

```bash
vim validating-policy.yaml
```

Add:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-team-label
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]

  validations:
    - expression: >
        has(object.metadata.labels) &&
        object.metadata.labels.exists(k, k == "team")
      message: "Pod must have a team label"
```

Apply:

```bash
kubectl apply -f validating-policy.yaml
```

Check:

```bash
kubectl get validatingadmissionpolicy
```

Expected:

```text
NAME
require-team-label
```

---

# 11. Create the Validating Policy Binding

Create:

```bash
vim validating-binding.yaml
```

Add:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-team-label-binding
spec:
  policyName: require-team-label

  validationActions:
    - Deny
```

Apply:

```bash
kubectl apply -f validating-binding.yaml
```

Check:

```bash
kubectl get validatingadmissionpolicybinding
```

---

# 12. Test an Invalid Pod

Create:

```bash
vim invalid-pod.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: invalid-validation-demo
spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Notice:

```text
No team label
```

Try to create it:

```bash
kubectl apply -f invalid-pod.yaml
```

The API server should reject the request with a message similar to:

```text
The Pod "invalid-validation-demo" is invalid:
Pod must have a team label
```

Verify:

```bash
kubectl get pod invalid-validation-demo
```

Expected:

```text
Error from server (NotFound):
pods "invalid-validation-demo" not found
```

The Pod was never created.

---

# 13. Create a Valid Pod

Now create a Pod with the required label.

Create:

```bash
vim valid-pod.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: valid-validation-demo
  labels:
    team: devops
spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f valid-pod.yaml
```

Expected:

```text
pod/valid-validation-demo created
```

Verify:

```bash
kubectl get pod valid-validation-demo --show-labels
```

Expected:

```text
NAME                     READY   STATUS    LABELS
valid-validation-demo    1/1     Running   team=devops
```

---

# 14. What Happened?

The invalid request:

```yaml
metadata:
  name: invalid-validation-demo
```

was evaluated by:

```text
Validating Admission Policy
          │
          ▼
Does Pod have "team" label?
          │
       ┌──┴──┐
       │     │
      YES    NO
       │     │
     ALLOW  DENY
```

Because the label was missing:

```text
CREATE → DENY
```

The object never reached persistent storage.

---

# 15. Mutating vs Validating

| Feature | Mutating | Validating |
|---|---|---|
| Modify request | ✅ Yes | ❌ No |
| Validate request | Can participate indirectly | ✅ Yes |
| Reject request | Not its primary function | ✅ Yes |
| Add defaults | ✅ | ❌ |
| Enforce rules | Usually no | ✅ |
| Example | Add label | Require label |
| Question | "How should I change it?" | "Should I allow it?" |

Remember:

```text
MUTATING
   ↓
CHANGE

VALIDATING
   ↓
CHECK
```

---

# 16. Complete Workflow

The complete demonstration can be represented as:

```text
              kubectl apply
                    │
                    ▼
              Kubernetes API
                  Server
                    │
                    ▼
          ┌───────────────────┐
          │ Mutating Policy   │
          │                   │
          │ Add label         │
          │ admission=mutated │
          └─────────┬─────────┘
                    │
                    ▼
          Modified Kubernetes
               Object
                    │
                    ▼
          ┌───────────────────┐
          │ Validating Policy │
          │                   │
          │ Check team label  │
          └─────────┬─────────┘
                    │
             ┌──────┴──────┐
             │             │
          team exists    missing
             │             │
             ▼             ▼
           ALLOW          DENY
             │
             ▼
            etcd
```

---

# 17. Useful Commands

## List admission policies

```bash
kubectl get mutatingadmissionpolicy
```

```bash
kubectl get validatingadmissionpolicy
```

## Describe policies

```bash
kubectl describe mutatingadmissionpolicy add-admission-label
```

```bash
kubectl describe validatingadmissionpolicy require-team-label
```

## List bindings

```bash
kubectl get mutatingadmissionpolicybinding
```

```bash
kubectl get validatingadmissionpolicybinding
```

## Inspect the final Pod

```bash
kubectl get pod nginx-mutating-demo -o yaml
```

## Inspect labels

```bash
kubectl get pods --show-labels
```

---

# 18. Cleanup

Delete the demonstration Pods:

```bash
kubectl delete pod nginx-mutating-demo
kubectl delete pod valid-validation-demo
```

Delete the admission policies:

```bash
kubectl delete mutatingadmissionpolicy add-admission-label
```

```bash
kubectl delete validatingadmissionpolicy require-team-label
```

Delete the bindings:

```bash
kubectl delete mutatingadmissionpolicybinding add-admission-label-binding
```

```bash
kubectl delete validatingadmissionpolicybinding require-team-label-binding
```

Or clean up using the YAML files:

```bash
kubectl delete -f mutating-policy.yaml
kubectl delete -f mutating-binding.yaml
kubectl delete -f validating-policy.yaml
kubectl delete -f validating-binding.yaml
kubectl delete -f nginx.yaml
kubectl delete -f valid-pod.yaml
```

---

# 19. CKA / CKAD / CKS Exam Concept

### Mutating

```text
Request
   │
   ▼
Mutating
   │
   ▼
Modified Request
```

Think:

> **"Change it."**

Examples:

```text
Add labels
Add annotations
Set defaults
Inject configuration
```

### Validating

```text
Request
   │
   ▼
Validating
   │
   ├── Valid → ALLOW
   │
   └── Invalid → DENY
```

Think:

> **"Check it."**

Examples:

```text
Require labels
Enforce security rules
Reject invalid configurations
Enforce organizational policies
```

---

# 20. Real-World Examples

## Mutating

A company wants every Pod to automatically receive:

```yaml
labels:
  environment: production
```

Instead of developers manually adding the label:

```text
Developer
   │
   ▼
Pod
   │
   ▼
Mutating Admission Controller
   │
   ▼
environment=production added
```

---

## Validating

A company says:

> Every production Pod must have a resource limit.

A validating admission controller can reject:

```yaml
containers:
- name: nginx
  image: nginx
```

and allow:

```yaml
containers:
- name: nginx
  image: nginx
  resources:
    limits:
      cpu: "500m"
      memory: "256Mi"
```

Conceptually:

```text
             Pod
              │
              ▼
       Validation Rule
              │
        ┌─────┴─────┐
        │           │
       YES          NO
        │           │
      ALLOW        DENY
```

---

# 21. One-Line Memory Trick

```text
┌──────────────────────────────────────┐
│ MUTATING   = MODIFY                  │
│ VALIDATING = VERIFY                  │
└──────────────────────────────────────┘
```

Or simply:

```text
Mutating   → "Let me change it."
Validating → "Let me check it."
```

---

# 22. Lab Files

At the end of the lab you should have:

```text
admission-demo/
│
├── mutating-policy.yaml
├── mutating-binding.yaml
├── nginx.yaml
│
├── validating-policy.yaml
├── validating-binding.yaml
├── invalid-pod.yaml
└── valid-pod.yaml
```

These files demonstrate the complete admission-control workflow.