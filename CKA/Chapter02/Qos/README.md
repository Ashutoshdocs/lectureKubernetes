# Kubernetes Quality of Service (QoS) Classes — Hands‑On Lab

A companion to the Priority & Preemption lab. This one teaches **how the
kubelet ranks Pods when a node runs out of memory**, and how the requests and
limits *you* write silently decide each Pod's fate.

By the end you will be able to:

- Name the three QoS classes and state the exact rule for each.
- Predict a Pod's QoS class just by reading its `resources:` block.
- Read the class Kubernetes actually assigned (`.status.qosClass`).
- Show that a memory limit is a hard cap (`OOMKilled`).
- Observe eviction **order** under node memory pressure.
- Explain why QoS is *not* the same thing as Priority.

---

## 1. The mental model

You do **not** set QoS. The kubelet computes it from your requests/limits and
uses it to decide who dies first when memory gets tight.

| Concept | Decided by | Question it answers |
|---|---|---|
| **QoS class** (this lab) | the **kubelet** | "When a *node* runs out of memory, whose Pods get killed first?" |
| **Priority** (other lab) | the **scheduler** | "When Pods compete for a spot, who gets scheduled — and may I evict someone?" |

They can even disagree: a low‑priority Pod can be `Guaranteed`, and a
high‑priority Pod can be `BestEffort`. Priority governs *scheduling*; QoS
governs *node‑pressure eviction*.

---

## 2. The three classes (the whole ruleset)

| Class | Rule | Eviction under memory pressure |
|---|---|---|
| **Guaranteed** | Every container has memory **and** CPU set, with `request == limit` for both | Evicted **last** — most protected |
| **Burstable** | Not Guaranteed, but at least one container sets some request or limit | Evicted **in the middle** |
| **BestEffort** | No container sets **any** request or limit | Evicted **first** — least protected |

Two things people trip on:

- Setting **only limits** (no requests) still gives **Guaranteed**, because
  Kubernetes auto‑copies each limit into the matching request.
- A single request or limit on a single container is enough to lift a Pod out
  of BestEffort into Burstable.

---

## 3. Files in this lab

| File | QoS it produces | Lesson |
|---|---|---|
| `01-guaranteed-pod.yaml` | Guaranteed | request == limit for CPU + memory |
| `02-burstable-pod.yaml` | Burstable | request < limit |
| `03-besteffort-pod.yaml` | BestEffort | no `resources:` at all |
| `04-oom-killed-pod.yaml` | Guaranteed | a limit is a hard cap → `OOMKilled` |
| `05-eviction-demo.yaml` | one of each | eviction **order** under pressure |

---

## 4. Prerequisites

- A test cluster (`minikube`, `kind`, k3s, …) and `kubectl`.
- The `polinux/stress` image is used to allocate memory on demand (pulled from
  Docker Hub); make sure your cluster can pull it.

---

## 5. Demo 1 — see the class Kubernetes assigns

```bash
kubectl apply -f 01-guaranteed-pod.yaml
kubectl apply -f 02-burstable-pod.yaml
kubectl apply -f 03-besteffort-pod.yaml

# The kubelet-derived class for each Pod:
kubectl get pods -l demo=qos \
  -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
```

Expected:

```
NAME             QOS
besteffort-pod   BestEffort
burstable-pod    Burstable
guaranteed-pod   Guaranteed
```

Try to *break* your prediction: edit `02-burstable-pod.yaml` so its requests
equal its limits, re‑apply, and watch it flip to `Guaranteed`. Delete the
`resources:` block entirely and it becomes `BestEffort`. This is the fastest
way to internalize the rules.

> `.status.qosClass` is read‑only — you can't request a class, only shape the
> requests/limits that produce it.

---

## 6. Demo 2 — a memory limit is a hard cap (`OOMKilled`)

```bash
kubectl apply -f 04-oom-killed-pod.yaml
kubectl get pod oom-demo -w
kubectl describe pod oom-demo | grep -A4 "Last State"
```

The container asks for ~250Mi but its limit is 100Mi, so the kernel kills it
the instant it crosses the line. You'll see `RESTARTS` climb and a
`Reason: OOMKilled` in the container's last state.

**The point:** this Pod is `Guaranteed`, yet it still gets killed. Guaranteed
means "won't be evicted to make room for *other* Pods" — it does **not** mean
"may exceed my own limit." Every QoS class is subject to its own limits.

---

## 7. Demo 3 — eviction order under node pressure

```bash
kubectl apply -f 05-eviction-demo.yaml
kubectl get pods -l demo=qos-evict -o wide -w

# In a second terminal, ramp up pressure until the kubelet starts reclaiming:
kubectl scale deployment/besteffort-hog --replicas=20    # raise until eviction fires
kubectl get events --sort-by=.metadata.creationTimestamp | grep -iE "evict|OOM"
```

What to observe, in order:

1. `besteffort-hog` replicas get **Evicted** first.
2. If pressure continues, `burstable-victim` goes next.
3. `guaranteed-survivor` holds on the longest.

> Node‑pressure eviction depends on your node's RAM and the kubelet's eviction
> thresholds, so the exact replica count that triggers it varies. The **order**
> is the lesson — if nothing evicts, add more replicas.

---

## 8. How the kubelet actually picks victims

Under memory pressure the kubelet ranks Pods by, roughly:

1. **Is the Pod using more memory than it requested?** Pods over their request
   are targeted first. BestEffort requests nothing, so it is *always* "over."
2. **Pod Priority** — lower priority is evicted before higher (this is where the
   two labs meet).
3. **How far over request** the Pod is — the biggest offenders go first.

There's also a lower‑level backstop: the kernel's OOM killer uses an
`oom_score_adj` derived from QoS. BestEffort gets the highest score (most
likely to be killed), Guaranteed the lowest. Inspect it:

```bash
POD=besteffort-pod
kubectl exec $POD -- cat /proc/1/oom_score_adj
```

---

## 9. Cheat‑sheet

| To get… | Do this in every container |
|---|---|
| **Guaranteed** | Set memory + CPU, `request == limit` for both |
| **Burstable** | Set at least one request/limit; keep at least one `request < limit` (or omit CPU) |
| **BestEffort** | Set nothing — no `resources:` block |

```bash
# One-liner to see the QoS of anything:
kubectl get pod <name> -o jsonpath='{.status.qosClass}{"\n"}'
```

---

## 10. Gotchas & troubleshooting

- **"I set requests==limits but it's Burstable."** You probably set them for
  memory only, or only on one of several containers. **Every** container needs
  CPU *and* memory with `request == limit`.
- **CPU limits don't cause eviction.** Exceeding a CPU limit throttles the
  container; it is not killed. Only **memory** pressure drives QoS eviction and
  `OOMKilled`.
- **Nothing gets evicted in Demo 3.** Your node has plenty of RAM — scale the
  BestEffort hog higher, or run on a smaller node.
- **`polinux/stress` won't pull.** Use any image that can allocate memory, or
  a `busybox` loop; only the memory growth matters.
- **QoS vs Priority confusion.** Priority changes *scheduling and preemption*;
  QoS changes *which running Pod the kubelet kills under memory pressure*. Set
  both intentionally — they are independent knobs.

---

## 11. Clean up

```bash
kubectl delete -f 05-eviction-demo.yaml --ignore-not-found
kubectl delete -f 04-oom-killed-pod.yaml --ignore-not-found
kubectl delete -f 03-besteffort-pod.yaml --ignore-not-found
kubectl delete -f 02-burstable-pod.yaml  --ignore-not-found
kubectl delete -f 01-guaranteed-pod.yaml --ignore-not-found

# or sweep everything this lab labelled:
kubectl delete pods,deployments -l demo=qos
kubectl delete pods,deployments -l demo=qos-evict
```

---

### One‑line summary to leave students with

> You don't choose a QoS class — Kubernetes reads your requests/limits and
> assigns one: **request == limit everywhere → Guaranteed**, **some but not all
> → Burstable**, **nothing → BestEffort** — and under memory pressure it kills
> BestEffort first and Guaranteed last.
