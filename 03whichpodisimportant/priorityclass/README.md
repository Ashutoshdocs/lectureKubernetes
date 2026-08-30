# Kubernetes Pod Priority & Preemption — Hands‑On Lab

A small, self‑contained lab for teaching **how Kubernetes decides which Pods
get scheduled when resources run out**, and how a high‑priority Pod can *evict*
a lower‑priority one to claim a node.

By the end you will be able to:

- Explain what a `PriorityClass` is and how a Pod uses it.
- Predict which Pod the scheduler places first.
- Trigger and observe **preemption** (eviction of a running Pod).
- Tell the difference between *preempting* and *non‑preempting* priority.
- Explain why Pod **priority** is not the same thing as Pod **QoS**.

---

## 1. The mental model

Two separate things use resource numbers, and beginners mix them up:

| Concept | Decided by | Question it answers |
|---|---|---|
| **Priority** (this lab) | the **scheduler** | "When Pods compete for a spot, who gets scheduled — and may I evict someone to make room?" |
| **QoS class** | the **kubelet** | "When a *node* runs out of memory, whose Pods get killed first?" |

This lab is about the first one. A `PriorityClass` attaches a number to a Pod.
Higher number = more important. The scheduler uses it to:

1. **Order the queue** — higher‑priority pending Pods are placed before lower ones.
2. **Preempt** — if a high‑priority Pod is stuck `Pending` for lack of room, the
   scheduler looks for lower‑priority Pods it can evict to free space, then
   schedules the high‑priority Pod there.

> `PriorityClass` objects are **cluster‑scoped** — they don't live in a namespace.
> Pods that reference them can be in any namespace.

---

## 2. Files in this lab

| File | What it creates |
|---|---|
| `01-priorityclasses.yaml` | `low-priority` (1000), `high-priority` (100000), and a bonus `high-priority-no-preempt` |
| `02-low-priority-pod.yaml` | A hungry Pod tagged low priority |
| `03-high-priority-pod.yaml` | A same‑sized Pod tagged high priority |
| `04-filler-deployment.yaml` | A scalable low‑priority Deployment for a reliable demo on any node size |

---

## 3. Prerequisites

- A cluster you can experiment on: `minikube`, `kind`, k3s, or any test cluster.
- `kubectl` pointed at it (`kubectl get nodes` works).

Check what you're working with:

```bash
kubectl get nodes
kubectl describe node <node-name> | grep -A5 "Allocatable"
```

Note the **Allocatable cpu** — you'll size the demo against it below.

---

## 4. Sizing the demo for your cluster (important)

Preemption only happens when a Pod **cannot fit**. If your node is big enough
to hold both the low‑ and high‑priority Pods, nothing is evicted and the lesson
falls flat. The uploaded originals used a fixed `1500m` for both Pods, which
only demonstrates preemption on a *small* node (≈2 vCPU).

Two ways to guarantee a good demo:

- **Path A (quick):** on a small node (kind/minikube default ≈ 2 CPU), the
  provided `1500m` requests already work — two of them can't coexist. Just make
  sure `1500m` is more than half your node's allocatable CPU.
- **Path B (reliable, any node):** ignore node size and use the **filler
  Deployment** — scale it until the node is full, then drop in the high‑priority
  Pod.

---

## 5. Apply the priority classes

```bash
kubectl apply -f 01-priorityclasses.yaml
kubectl get priorityclass
```

You'll see your three classes alongside the built‑in `system-cluster-critical`
and `system-node-critical` (those sit above 1e9 and are reserved for the
control plane — don't use them for app Pods).

---

## 6. Path A — the quick two‑Pod demo

```bash
# 1. Schedule the low-priority Pod first; it grabs the CPU.
kubectl apply -f 02-low-priority-pod.yaml
kubectl get pods -o wide          # low-priority-pod -> Running

# 2. Now ask for the high-priority Pod. There isn't room...
kubectl apply -f 03-high-priority-pod.yaml

# 3. ...so the scheduler preempts the low-priority Pod.
kubectl get pods -w
```

Expected sequence: `low-priority-pod` goes `Running -> Terminating -> gone`,
and `high-priority-pod` moves `Pending -> Running` on that freed node.

Confirm *why* it happened:

```bash
kubectl get events --sort-by=.metadata.creationTimestamp | tail -n 20
```

Look for a **Preempted** event on the low‑priority Pod and a
`nominated node` / scheduling event on the high‑priority Pod.

---

## 7. Path B — the reliable filler demo (recommended for class)

```bash
# 1. Deploy the filler and pack the node.
kubectl apply -f 04-filler-deployment.yaml
kubectl scale deployment/low-priority-filler --replicas=8   # raise until one is Pending
kubectl get pods -l app=low-priority-filler

# When the node is full you'll see some replicas stuck in Pending — good, that
# means allocatable CPU is exhausted.

# 2. Introduce the high-priority Pod.
kubectl apply -f 03-high-priority-pod.yaml
kubectl get pods -w
```

Watch the scheduler evict **just enough** filler replicas (the lowest‑priority
tenants) to fit the high‑priority Pod. The Deployment then tries to recreate
the evicted replicas, which land in `Pending` because the node is still full —
a nice illustration that priority governs *who waits*.

---

## 8. Inspecting what happened

```bash
# The resolved numeric priority the scheduler assigned each Pod:
kubectl get pod low-priority-pod  -o yaml | grep -i priority
kubectl get pod high-priority-pod -o yaml | grep -i priority

# Full timeline of scheduling + preemption events:
kubectl get events --sort-by=.metadata.creationTimestamp

# Why a specific Pod is Pending (great teaching output):
kubectl describe pod high-priority-pod
```

`kubectl describe` on a preempting Pod shows a `Preempted` / `nominatedNodeName`
line; the victim Pod's events show it was evicted to make room.

---

## 9. Bonus experiment — non‑preempting priority

Repeat Path A, but point the high‑priority Pod at `high-priority-no-preempt`
(edit `03-high-priority-pod.yaml`, change `priorityClassName` to
`high-priority-no-preempt`, re‑apply).

Now the high‑priority Pod has a high *queue* position but **will not evict**
anyone. On a full node it simply stays `Pending` until space frees up naturally.
This isolates the two jobs priority does: *ordering* vs *preemption*.

---

## 10. Key fields cheat‑sheet

| Field | Where | Meaning |
|---|---|---|
| `value` | PriorityClass | The integer weight. Higher wins. ≤ 1e9 for user classes. |
| `globalDefault` | PriorityClass | If `true`, Pods with no class get this value. Only one class may set it. |
| `preemptionPolicy` | PriorityClass | `PreemptLowerPriority` (default) or `Never`. |
| `description` | PriorityClass | Free text; shows in `kubectl get priorityclass`. |
| `priorityClassName` | Pod `spec` | Which class this Pod uses. |
| `priority` | Pod `spec` | Read‑only; the scheduler fills it in from the class. |

---

## 11. Gotchas & troubleshooting

- **Nothing got preempted.** The node had room for both Pods. Increase the CPU
  request, use a smaller node, or switch to the filler Deployment (Path B).
- **High‑priority Pod stuck `Pending`, no eviction.** Check its class isn't
  `preemptionPolicy: Never`, and that lower‑priority victims actually exist on a
  node where removing them would let it fit.
- **`priorityClassName` not found error.** Apply `01-priorityclasses.yaml`
  first; a Pod referencing a missing class is rejected.
- **PodDisruptionBudgets.** Preemption respects PDBs on a best‑effort basis; a
  tight PDB can slow or block eviction of victims.
- **Preempted Pods aren't rescheduled.** Bare Pods (Path A) are gone for good
  once evicted — only controllers (Deployment/ReplicaSet) recreate them.
- **Priority ≠ guaranteed to run.** It affects *ordering* and *preemption*, not
  raw capacity. A Pod bigger than any node stays `Pending` no matter its priority.

---

## 12. Clean up

```bash
kubectl delete -f 03-high-priority-pod.yaml --ignore-not-found
kubectl delete -f 02-low-priority-pod.yaml  --ignore-not-found
kubectl delete -f 04-filler-deployment.yaml --ignore-not-found
kubectl delete -f 01-priorityclasses.yaml   --ignore-not-found

# or sweep everything this lab labelled:
kubectl delete pods,deployments -l demo=priority-preemption
```

---

### One‑line summary to leave students with

> A `PriorityClass` puts a number on a Pod; the scheduler places higher numbers
> first, and — unless told `preemptionPolicy: Never` — will evict lower‑numbered
> Pods to make room when the cluster is full.
