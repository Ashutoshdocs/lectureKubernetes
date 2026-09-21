# Kubernetes Taints & Tolerations — Practical Demo

## Objective

This demo proves how Kubernetes **taints** and **tolerations** control which Pods can be scheduled on a Node.

We will perform two practical approaches:

1. Find a Node using its **node name** → add taint → verify → remove taint.
2. Find a Node using a **label** → add taint → verify → remove taint.

We will also create Pods **with and without tolerations** to prove the scheduling behavior.

---

# 1. Understand the Concept

A taint is applied to a **Node**:

```text
Node
  │
  └── Taint
       │
       ├── key=value
       └── effect
```

A Pod needs a matching **toleration** to be allowed onto that Node.

```text
Node
  │
  │ taint
  ▼
No matching toleration
       │
       ▼
   ❌ Pod rejected
```

With a matching toleration:

```text
Node
  │
  │ key=team:NoSchedule
  ▼
Pod
  │
  │ matching toleration
  ▼
✅ Pod can schedule
```

> **Important:** A toleration does not force a Pod onto a tainted Node. It only allows the Pod to be scheduled there.

---

# 2. Check Existing Nodes

Start by listing Nodes:

```bash
kubectl get nodes
```

Example:

```text
NAME          STATUS   ROLES           AGE
master        Ready    control-plane   20d
worker01      Ready    <none>          20d
worker02      Ready    <none>          20d
```

Get more details:

```bash
kubectl get nodes -o wide
```

---

# 3. Check Existing Taints

Check taints on all Nodes:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Example:

```text
NAME       TAINTS
master     [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane]]
worker01   <none>
worker02   <none>
```

For one specific Node:

```bash
kubectl describe node worker01
```

Look for:

```text
Taints:
```

---

# PART A — TAINT USING NODE NAME

# 4. Select a Node by Name

Set the Node name:

```bash
NODE=worker01
```

Verify:

```bash
kubectl get node $NODE
```

You can also directly use:

```bash
kubectl get node worker01
```

---

# 5. Add a Taint to the Node

Add:

```text
dedicated=training:NoSchedule
```

Command:

```bash
kubectl taint nodes $NODE dedicated=training:NoSchedule
```

Equivalent:

```bash
kubectl taint nodes worker01 dedicated=training:NoSchedule
```

Expected:

```text
node/worker01 tainted
```

---

# 6. Verify the Taint

Run:

```bash
kubectl describe node $NODE | grep -i taint
```

Expected:

```text
Taints: dedicated=training:NoSchedule
```

Or:

```bash
kubectl get node $NODE -o jsonpath='{.spec.taints}'
```

Expected output similar to:

```text
[{"effect":"NoSchedule","key":"dedicated","value":"training"}]
```

---

# 7. Create a Pod WITHOUT Toleration

Create:

```bash
nano no-toleration.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: no-toleration

spec:
  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f no-toleration.yaml
```

Check:

```bash
kubectl get pod no-toleration -o wide
```

Depending on the other Nodes available, Kubernetes may schedule the Pod elsewhere.

To prove the tainted Node rejects it, use a cluster where the tainted Node is the only eligible Node, or combine the taint test with a nodeSelector/node affinity.

Check scheduling events:

```bash
kubectl describe pod no-toleration
```

Look at:

```text
Events:
```

You may see:

```text
0/2 nodes are available:
1 node(s) had untolerated taint
```

---

# 8. Create a Pod WITH Toleration

Create:

```bash
nano toleration.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: toleration-demo

spec:

  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "training"
      effect: "NoSchedule"

  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f toleration.yaml
```

Check:

```bash
kubectl get pod toleration-demo -o wide
```

The Pod is now **allowed** to run on the tainted Node.

> It is important to understand that the toleration makes the Node eligible; it does not guarantee that Kubernetes will choose that Node.

---

# 9. Force the Test Pod to the Tainted Node

For a clean demonstration, combine toleration with `nodeName`.

Create:

```bash
nano toleration-node.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: toleration-node-demo

spec:

  nodeName: worker01

  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "training"
      effect: "NoSchedule"

  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f toleration-node.yaml
```

Verify:

```bash
kubectl get pod toleration-node-demo -o wide
```

Expected:

```text
NAME                   READY   STATUS    NODE
toleration-node-demo   1/1     Running   worker01
```

This proves:

```text
worker01
   │
   ├── dedicated=training:NoSchedule
   │
   └── Pod has matching toleration
             │
             ▼
          ✅ Allowed
```

---

# 10. Remove the Taint

Remove the taint using the same key and effect:

```bash
kubectl taint nodes $NODE dedicated=training:NoSchedule-
```

Or:

```bash
kubectl taint nodes worker01 dedicated=training:NoSchedule-
```

Expected:

```text
node/worker01 untainted
```

---

# 11. Verify Taint Removal

```bash
kubectl describe node $NODE | grep -i taint
```

Or:

```bash
kubectl get node $NODE -o jsonpath='{.spec.taints}'
```

If there are no taints:

```text
[]
```

or the output may be empty.

---

# PART B — FIND NODE USING LABEL

Now we will identify the Node using a **label** instead of manually specifying the Node name.

---

# 12. Check Node Labels

Run:

```bash
kubectl get nodes --show-labels
```

Example:

```text
NAME       STATUS   LABELS
worker01   Ready    kubernetes.io/hostname=worker01,...
worker02   Ready    kubernetes.io/hostname=worker02,...
```

---

# 13. Add Our Own Label

For example:

```bash
kubectl label node worker01 workload=training
```

Expected:

```text
node/worker01 labeled
```

Verify:

```bash
kubectl get nodes -l workload=training
```

Expected:

```text
NAME
worker01
```

This allows us to find the Node without hardcoding its name.

---

# 14. Get the Node Name From the Label

Run:

```bash
kubectl get nodes -l workload=training -o name
```

Expected:

```text
node/worker01
```

You can also retrieve only the name:

```bash
kubectl get nodes -l workload=training \
  -o jsonpath='{.items[0].metadata.name}'
```

Output:

```text
worker01
```

Store it:

```bash
NODE=$(kubectl get nodes -l workload=training \
  -o jsonpath='{.items[0].metadata.name}')
```

Verify:

```bash
echo $NODE
```

---

# 15. Add Taint to the Label-Selected Node

Now taint the Node found through the label:

```bash
kubectl taint node $NODE dedicated=training:NoSchedule
```

Expected:

```text
node/worker01 tainted
```

Notice the workflow:

```text
Label
  │
  ▼
workload=training
  │
  ▼
Find Node
  │
  ▼
worker01
  │
  ▼
Add Taint
  │
  ▼
dedicated=training:NoSchedule
```

---

# 16. Verify

Check the selected Node:

```bash
kubectl describe node $NODE | grep -i taint
```

Expected:

```text
Taints: dedicated=training:NoSchedule
```

Check the label:

```bash
kubectl get node $NODE --show-labels
```

You should see:

```text
workload=training
```

---

# 17. Verify Scheduling With a Matching Toleration

Create:

```bash
nano label-taint-demo.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: label-taint-demo

spec:

  nodeSelector:
    workload: training

  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "training"
      effect: "NoSchedule"

  containers:
    - name: nginx
      image: nginx:alpine
```

Apply:

```bash
kubectl apply -f label-taint-demo.yaml
```

Check:

```bash
kubectl get pod label-taint-demo -o wide
```

Expected:

```text
NAME               READY   STATUS    NODE
label-taint-demo   1/1     Running   worker01
```

This is an excellent demonstration because:

```text
Pod
 │
 ├── nodeSelector
 │       │
 │       └── workload=training
 │
 └── toleration
         │
         └── dedicated=training:NoSchedule
                    │
                    ▼
                  Node
                    │
                    ├── workload=training
                    └── dedicated=training:NoSchedule
```

Both conditions are satisfied.

---

# 18. Remove the Taint Again

```bash
kubectl taint node $NODE dedicated=training:NoSchedule-
```

Expected:

```text
node/worker01 untainted
```

Verify:

```bash
kubectl describe node $NODE | grep -i taint
```

---

# 19. Remove the Label

If the label was created only for this demo:

```bash
kubectl label node $NODE workload-
```

Verify:

```bash
kubectl get node $NODE --show-labels
```

The `workload=training` label should be gone.

---

# 20. Cleanup Pods

```bash
kubectl delete pod no-toleration
kubectl delete pod toleration-demo
kubectl delete pod toleration-node-demo
kubectl delete pod label-taint-demo
```

---

# 21. Useful Taint Commands

## List all Nodes

```bash
kubectl get nodes
```

## Show labels

```bash
kubectl get nodes --show-labels
```

## Find Nodes using a label

```bash
kubectl get nodes -l workload=training
```

## Add a label

```bash
kubectl label node worker01 workload=training
```

## Remove a label

```bash
kubectl label node worker01 workload-
```

## Add taint

```bash
kubectl taint node worker01 dedicated=training:NoSchedule
```

## Remove taint

```bash
kubectl taint node worker01 dedicated=training:NoSchedule-
```

## Check taints

```bash
kubectl describe node worker01 | grep -i taint
```

## Check taints for all Nodes

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

# 22. Different Taint Effects

There are three major taint effects.

## NoSchedule

```text
key=value:NoSchedule
```

New Pods without a matching toleration are not scheduled onto the Node.

Existing Pods generally remain.

---

## PreferNoSchedule

```text
key=value:PreferNoSchedule
```

Kubernetes tries to avoid placing Pods on the Node but does not strictly prohibit scheduling.

---

## NoExecute

```text
key=value:NoExecute
```

This affects both:

```text
New Pods
+
Existing Pods
```

Pods without the appropriate toleration can be evicted from the Node.

Example:

```bash
kubectl taint node worker01 maintenance=true:NoExecute
```

---

# 23. Important Difference — Taint vs Label

This is a common interview question.

### Label

A label helps Kubernetes **select** Nodes.

```text
Node:
workload=training

Pod:
nodeSelector:
  workload: training
```

Meaning:

```text
"Put this Pod on a Node having this label."
```

---

### Taint

A taint tells Kubernetes:

```text
"Do not put normal Pods here."
```

Example:

```text
dedicated=training:NoSchedule
```

A Pod needs a matching toleration.

---

# 24. Combining Label + Taint

This is commonly useful in real environments.

Node:

```text
Label:
workload=training

Taint:
dedicated=training:NoSchedule
```

Pod:

```text
nodeSelector:
  workload: training

tolerations:
  - key: dedicated
    operator: Equal
    value: training
    effect: NoSchedule
```

The result:

```text
                    Node
                     │
       ┌─────────────┴─────────────┐
       │                           │
       ▼                           ▼
  Label matches              Toleration matches
       │                           │
       └─────────────┬─────────────┘
                     ▼
               Pod can run
```

This gives you **dedicated Node behavior**.

---

# 25. Complete Demo Flow

Use this sequence during teaching:

```bash
# 1. Check nodes
kubectl get nodes

# 2. Check taints
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# 3. Select node
NODE=worker01

# 4. Add taint
kubectl taint node $NODE dedicated=training:NoSchedule

# 5. Verify
kubectl describe node $NODE | grep -i taint

# 6. Test pod without toleration
kubectl apply -f no-toleration.yaml

# 7. Check scheduling
kubectl get pod no-toleration -o wide
kubectl describe pod no-toleration

# 8. Test pod with toleration
kubectl apply -f toleration.yaml

# 9. Verify
kubectl get pod toleration-demo -o wide

# 10. Remove taint
kubectl taint node $NODE dedicated=training:NoSchedule-

# 11. Verify removal
kubectl describe node $NODE | grep -i taint
```

---

# 26. Label-Based Flow

```bash
# Add label
kubectl label node worker01 workload=training

# Find node using label
kubectl get nodes -l workload=training

# Automatically get node name
NODE=$(kubectl get nodes \
  -l workload=training \
  -o jsonpath='{.items[0].metadata.name}')

# Verify
echo $NODE

# Add taint
kubectl taint node $NODE dedicated=training:NoSchedule

# Verify
kubectl describe node $NODE | grep -i taint

# Deploy pod with nodeSelector + toleration
kubectl apply -f label-taint-demo.yaml

# Verify
kubectl get pod label-taint-demo -o wide

# Remove taint
kubectl taint node $NODE dedicated=training:NoSchedule-

# Remove label
kubectl label node $NODE workload-
```

---

# 27. Interview Summary

### Question: What is a taint?

A taint is applied to a Node to restrict which Pods can be scheduled there.

### Question: What is a toleration?

A toleration is added to a Pod so that it can tolerate a matching Node taint.

### Question: Does a toleration force a Pod onto a Node?

**No.**

It only makes the Node eligible.

### Question: How do you force selection?

Use mechanisms such as:

```yaml
nodeSelector:
```

or:

```yaml
nodeAffinity:
```

### Question: Can we select a Node using a label?

Yes:

```bash
kubectl get nodes -l workload=training
```

### Question: How do you remove a taint?

```bash
kubectl taint node NODE_NAME KEY=VALUE:EFFECT-
```

Example:

```bash
kubectl taint node worker01 dedicated=training:NoSchedule-
```

---

# Final Mental Model

```text
                 NODE
                   │
          ┌────────┴────────┐
          │                 │
        LABEL              TAINT
          │                 │
          │                 │
   workload=training   dedicated=training
          │                 │
          │                 │
          ▼                 ▼
     nodeSelector      toleration
          │                 │
          └────────┬────────┘
                   ▼
                  POD
                   │
                   ▼
               SCHEDULED
```

## Remember

```text
LABEL       → "Which Node should I select?"
TAINT       → "Which Pods should stay away?"
TOLERATION  → "Which taint am I allowed to tolerate?"
```

**The strongest production pattern is often:**

```text
Node Label
     +
Node Taint
     +
Pod nodeSelector/nodeAffinity
     +
Pod toleration
```

This gives precise control over **where workloads are allowed to run and which workloads are allowed onto dedicated Nodes**.