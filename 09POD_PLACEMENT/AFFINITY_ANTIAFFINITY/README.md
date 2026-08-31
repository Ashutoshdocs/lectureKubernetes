# Kubernetes Scheduling Demo: Affinity & Anti-Affinity

A hands-on walkthrough of how the Kubernetes scheduler places Pods using
**node affinity**, **node anti-affinity**, **pod affinity**, and **pod
anti-affinity**. Run the manifests in the order below — each demo builds on the
concept before it.

---

## What you'll learn

| Concept | Question it answers | Manifests |
|---|---|---|
| Node affinity | "Only run me on nodes that look like *this*." | `node_affinity.yml` |
| Node anti-affinity | "Run me anywhere *except* that node." | `antinodeaffinity.yml` |
| Pod affinity | "Put me *next to* that other Pod." | `pod_affinity_driver.yml`, `pod_hunting_for_affinity_driver.yml` |
| Pod anti-affinity | "Keep me *away from* Pods like me." | `antipod_affinity_driver.yml`, `antipod_affinity_runaway.yml` |

The word **driver** = the Pod you deploy *first* to set the stage. The Pod
deployed *second* reacts to it (either "hunting" toward it or being "runaway"
because it can't be placed).

---

## Prerequisites

- A running cluster with **at least one worker node named `worker`** plus one
  other schedulable node (2+ nodes total). `kind`, `minikube --nodes 2`, or a
  kubeadm cluster all work.
- `kubectl` configured against the cluster.

Check your nodes first — you'll reference these names throughout:

```bash
kubectl get nodes --show-labels
```

Useful watch command to keep in a second terminal:

```bash
kubectl get pods -o wide -w
```

`-o wide` shows the **NODE** column, which is the whole point of these demos.

---

## Demo 1 — Node Affinity (`node_affinity.yml`)

**Goal:** the Pod must land on a node labeled `disk=ssd`. No such label exists
yet, so it will stay **Pending** until we create one.

### Steps

1. Apply the manifest:
   ```bash
   kubectl apply -f node_affinity.yml
   ```
2. Observe it stuck in `Pending` (no node matches `disk=ssd`):
   ```bash
   kubectl get pod node-affinity-pod -o wide
   kubectl describe pod node-affinity-pod | grep -A5 Events
   ```
   You'll see a message like `0/2 nodes are available: ... didn't match
   node affinity`.
3. Label a node to satisfy the rule:
   ```bash
   kubectl label node worker disk=ssd
   ```
4. The scheduler now places the Pod on `worker`:
   ```bash
   kubectl get pod node-affinity-pod -o wide
   ```

**Takeaway:** `requiredDuringSchedulingIgnoredDuringExecution` is a *hard*
rule. If no node matches, the Pod waits forever rather than compromising.

---

## Demo 2 — Node Anti-Affinity (`antinodeaffinity.yml`)

**Goal:** the same node-affinity mechanism, but expressed as a *repel* using the
`NotIn` operator. This Pod may run on any node **except** `worker`.

### Steps

1. Apply the manifest:
   ```bash
   kubectl apply -f antinodeaffinity.yml
   ```
2. Check where it landed — anywhere but `worker`:
   ```bash
   kubectl get pod node-anti-affinity-pod -o wide
   ```

**Takeaway:** Kubernetes has no separate "node anti-affinity" object. You get
anti-affinity by inverting the operator (`NotIn` / `DoesNotExist`) inside
`nodeAffinity`. If `worker` is your *only* schedulable node, this Pod will be
`Pending` — which is itself a good lesson about over-constraining.

---

## Demo 3 — Pod Affinity (driver, then the hunter)

**Goal:** a "frontend" Pod should always run on the **same node** as the
"backend" Pod. We deploy the backend first (the *driver*), then the frontend
that hunts for it.

> Order matters. Pod affinity is evaluated against Pods that already exist. If
> you deploy the frontend first, it has nothing to match and stays Pending.

### Step 3a — Deploy the driver (`pod_affinity_driver.yml`)

This Pod is pinned to `worker` via `nodeSelector` and carries the label
`app: backend`.

```bash
kubectl apply -f pod_affinity_driver.yml
kubectl get pod backend -o wide      # should be on 'worker'
```

### Step 3b — Deploy the hunter (`pod_hunting_for_affinity_driver.yml`)

This `frontend` Pod has `podAffinity` for `app=backend` with
`topologyKey: kubernetes.io/hostname`, meaning "same host as the backend."

```bash
kubectl apply -f pod_hunting_for_affinity_driver.yml
kubectl get pods -o wide             # frontend lands on the SAME node as backend
```

**Takeaway:** `topologyKey` defines *what counts as "together."*
`kubernetes.io/hostname` means same node; `topology.kubernetes.io/zone` would
mean same zone. Pod affinity co-locates workloads that benefit from being close.

---

## Demo 4 — Pod Anti-Affinity (driver, then the runaway)

**Goal:** two Pods that share the label `app: backendx` must **never** share a
node. On a single-worker setup, the second one has nowhere to go and becomes a
"runaway" — permanently Pending.

### Step 4a — Deploy the driver (`antipod_affinity_driver.yml`)

`backend-1` has `podAntiAffinity` against `app=backendx`. Since no such Pod
exists yet, it schedules normally.

```bash
kubectl apply -f antipod_affinity_driver.yml
kubectl get pod backend-1 -o wide    # schedules fine
```

### Step 4b — Deploy the runaway (`antipod_affinity_runaway.yml`)

`backend-2` has the same label and the same anti-affinity rule. It refuses to
share a node with `backend-1`.

```bash
kubectl apply -f antipod_affinity_runaway.yml
kubectl get pod backend-2 -o wide    # Pending if there's no second free node
kubectl describe pod backend-2 | grep -A5 Events
```

You'll see `didn't match pod anti-affinity rules`. Give it a home by adding a
second worker node (or freeing one), and it will schedule there.

**Takeaway:** Pod anti-affinity spreads replicas across nodes for high
availability — but a *hard* rule (`requiredDuringScheduling...`) can leave Pods
unschedulable if there aren't enough distinct topology domains. In production,
`preferredDuringScheduling...` is often the safer choice.

---

## Recommended run order (quick reference)

```bash
# 1. Node affinity — watch it wait, then satisfy it
kubectl apply -f node_affinity.yml
kubectl label node worker disk=ssd

# 2. Node anti-affinity — NotIn = repel
kubectl apply -f antinodeaffinity.yml

# 3. Pod affinity — driver first, then the hunter
kubectl apply -f pod_affinity_driver.yml
kubectl apply -f pod_hunting_for_affinity_driver.yml

# 4. Pod anti-affinity — driver first, then the runaway
kubectl apply -f antipod_affinity_driver.yml
kubectl apply -f antipod_affinity_runaway.yml
```

---

## Cleanup

```bash
kubectl delete -f node_affinity.yml \
               -f antinodeaffinity.yml \
               -f pod_affinity_driver.yml \
               -f pod_hunting_for_affinity_driver.yml \
               -f antipod_affinity_driver.yml \
               -f antipod_affinity_runaway.yml

# remove the label added during Demo 1
kubectl label node worker disk-
```

---

## Concept cheat-sheet

- **`requiredDuringSchedulingIgnoredDuringExecution`** — hard rule at scheduling
  time; ignored once the Pod is already running.
- **`preferredDuringScheduling...`** — soft rule; the scheduler tries, but will
  still place the Pod if it can't be satisfied.
- **Operators** — `In` / `NotIn` / `Exists` / `DoesNotExist`. Anti-affinity for
  *nodes* is just an inverted operator; anti-affinity for *pods* is its own
  field (`podAntiAffinity`).
- **`topologyKey`** — the node label that defines the "domain" of together vs.
  apart (`kubernetes.io/hostname`, `.../zone`, `.../region`).
