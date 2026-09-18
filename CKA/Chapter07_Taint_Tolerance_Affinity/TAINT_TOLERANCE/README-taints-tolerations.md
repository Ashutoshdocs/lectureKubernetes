# Kubernetes Scheduling Demo: Taints & Tolerations

A hands-on walkthrough of how a **taint** on a node repels Pods, and how a
matching **toleration** on a Pod lets it schedule there anyway.

Affinity (covered separately) is a Pod *attracting itself* to nodes. Taints are
the opposite direction of control: the **node pushes Pods away**, and only Pods
that explicitly tolerate the taint are allowed on.

---

## What you'll learn

| Concept | Who owns it | What it does |
|---|---|---|
| Taint | The **node** | Repels Pods that don't tolerate it |
| Toleration | The **Pod** | Lets the Pod ignore a matching taint |

The two manifests:

| Manifest | Toleration? | Expected result on a tainted node |
|---|---|---|
| `podwithoutTolerance.yml.txt` | none | Repelled — won't schedule on the tainted node |
| `podwithTolerance.yml` | `env=prod:NoSchedule` | Allowed — schedules on the tainted node |

> Both Pods are named `nginx`, so only one can exist at a time. Delete the first
> before applying the second.

---

## Prerequisites

- A running cluster with at least one worker node named `worker`
  (`kind`, `minikube`, or kubeadm all work).
- `kubectl` configured against the cluster.

Keep this in a second terminal to watch placement live:

```bash
kubectl get pods -o wide -w
```

`-o wide` shows the **NODE** column and the `STATUS` — the whole point here.

---

## How the taint matches the toleration

The toleration in `podwithTolerance.yml` must line up with the taint you place
on the node — key, value, and effect all have to agree:

```
Taint on node:        env=prod:NoSchedule
Toleration on Pod:    key=env  operator=Equal  value=prod  effect=NoSchedule
```

The three `NoSchedule`-family effects:

- **`NoSchedule`** — new Pods without a matching toleration are not scheduled
  here (existing Pods stay). *This is the one used in the demo.*
- **`PreferNoSchedule`** — soft version; the scheduler tries to avoid the node
  but will use it if needed.
- **`NoExecute`** — as above, *plus* it evicts already-running Pods that don't
  tolerate the taint.

---

## Step 1 — Taint the node

Push all Pods without a matching toleration away from `worker`:

```bash
kubectl taint nodes worker env=prod:NoSchedule
```

Confirm the taint is in place:

```bash
kubectl describe node worker | grep -i taints
# Taints:  env=prod:NoSchedule
```

---

## Step 2 — Deploy the Pod WITHOUT a toleration

```bash
kubectl apply -f podwithoutTolerance.yml.txt
kubectl get pod nginx -o wide
```

**Expected:** if `worker` is the only schedulable node, the Pod stays
`Pending` — it is not allowed onto the tainted node.

Check why:

```bash
kubectl describe pod nginx | grep -A5 Events
# ... 1 node(s) had untolerated taint {env: prod}, that the pod didn't tolerate
```

Clean up before the next step (the name is reused):

```bash
kubectl delete -f podwithoutTolerance.yml.txt
```

**Takeaway:** a `NoSchedule` taint is a hard gate. No matching toleration → the
Pod never lands on that node.

---

## Step 3 — Deploy the Pod WITH a toleration

```bash
kubectl apply -f podwithTolerance.yml
kubectl get pod nginx -o wide
```

**Expected:** the Pod schedules onto `worker`, because its toleration matches
the `env=prod:NoSchedule` taint.

**Takeaway:** a toleration does not *force* a Pod onto a tainted node — it only
*permits* it. The scheduler could still place it elsewhere. To pin it to a
specific node, combine tolerations with node affinity or a `nodeSelector`.

---

## Recommended run order (quick reference)

```bash
# 1. Taint the node so it repels untolerated Pods
kubectl taint nodes worker env=prod:NoSchedule

# 2. No toleration -> stays Pending (repelled)
kubectl apply -f podwithoutTolerance.yml.txt
kubectl get pod nginx -o wide
kubectl delete -f podwithoutTolerance.yml.txt

# 3. Matching toleration -> schedules on the tainted node
kubectl apply -f podwithTolerance.yml
kubectl get pod nginx -o wide
```

---

## Cleanup

```bash
# remove the Pod
kubectl delete -f podwithTolerance.yml --ignore-not-found

# remove the taint (note the trailing '-')
kubectl taint nodes worker env=prod:NoSchedule-
```

---

## Concept cheat-sheet

- **Taints repel; tolerations permit.** A toleration allows scheduling on a
  tainted node — it never guarantees or forces it.
- **Matching rule:** for `operator: Equal`, the Pod's `key`, `value`, and
  `effect` must all match the taint. Using `operator: Exists` (with no `value`)
  tolerates any value for that key.
- **Effects:** `NoSchedule` (block new Pods), `PreferNoSchedule` (soft avoid),
  `NoExecute` (block *and* evict).
- **Common real-world use:** control-plane nodes carry
  `node-role.kubernetes.io/control-plane:NoSchedule` so ordinary workloads stay
  off them; dedicated GPU/prod nodes are tainted so only opted-in Pods land there.
- **Taints vs. affinity:** affinity is the Pod choosing nodes it likes; taints
  are the node rejecting Pods it doesn't want. They're often used together.
