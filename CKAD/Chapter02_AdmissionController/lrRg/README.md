# ResourceQuota & LimitRange Demo (`rq-demo`)

A hands-on demo showing how a **LimitRange** (per-container defaults + min/max) and a
**ResourceQuota** (namespace-wide caps) work together to admit or reject Pods.

All manifests target the namespace **`rq-demo`**.

---

## Files

| File | Kind | Purpose |
|------|------|---------|
| `LimitRange.yml`     | LimitRange   | Per-container defaults, min and max for cpu/memory |
| `ResourceQuota.yml`  | ResourceQuota| Namespace-wide caps (pod count + total requests/limits) |
| `cpu_memory.yml`     | Pod `pod-full`        | Fully specified requests **and** limits — passes cleanly |
| `cpuonly.yml`        | Pod `pod-only-cpu`    | Only cpu set → memory filled from LimitRange defaults |
| `Onlymemory.yml`     | Pod `pod-only-memory` | Only memory set → cpu filled from LimitRange defaults |
| `nothingapplied.yml` | Pod `pod-no-resources`| No resources at all → everything filled from LimitRange |
| `fail01.yml`         | Pod `pod-memory-fail` | memory limit `10Gi` > max `512Mi` → **rejected** |
| `fail02.yml`         | Pod `pod-cpu-max-fail`| cpu limit `1` (1000m) > max `500m` → **rejected** |
| `fail03.yml`         | Pod `pod-heavy-request`| cpu req `2` / mem req `3Gi` → **rejected** |

### The policies at a glance

**LimitRange (`default-limits`, type: Container)**

| | cpu | memory |
|---|---|---|
| default (limit)      | 200m | 256Mi |
| defaultRequest       | 100m | 128Mi |
| min (request/limit)  | 50m  | 64Mi  |
| max (request/limit)  | 500m | 512Mi |

**ResourceQuota (`compute-quota`)**

| resource | hard cap |
|---|---|
| pods | 6 |
| requests.cpu | 1 (1000m) |
| requests.memory | 2Gi |
| limits.cpu | 2 (2000m) |
| limits.memory | 4Gi |

---

## Prerequisites

- A running cluster and `kubectl` pointing at it (`kubectl cluster-info`).
- No namespace manifest is included, so create it first (Step 0).

---

## Demo order

Run the steps top to bottom. Order matters: apply the **LimitRange and ResourceQuota
before the Pods** so admission control is in effect when the Pods are created.

### Step 0 — Create the namespace

```bash
kubectl create namespace rq-demo
```

### Step 1 — Apply the LimitRange

```bash
kubectl apply -f LimitRange.yml
kubectl describe limitrange default-limits -n rq-demo
```

### Step 2 — Apply the ResourceQuota

```bash
kubectl apply -f ResourceQuota.yml
kubectl describe resourcequota compute-quota -n rq-demo
# Used should be all zeros at this point.
```

### Step 3 — Apply the Pods that succeed (watch defaults get injected)

```bash
kubectl apply -f cpu_memory.yml      # pod-full: nothing to inject, passes as-is
kubectl apply -f cpuonly.yml         # memory defaults injected
kubectl apply -f Onlymemory.yml      # cpu defaults injected
kubectl apply -f nothingapplied.yml  # all four values injected
```

Verify the injected values and quota consumption:

```bash
# See the effective requests/limits after LimitRange mutation
kubectl get pod pod-no-resources -n rq-demo -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl get pod pod-only-cpu     -n rq-demo -o jsonpath='{.spec.containers[0].resources}'; echo

# Watch the quota fill up
kubectl describe resourcequota compute-quota -n rq-demo
```

What to point out:
- `pod-no-resources` ends up with requests `cpu=100m, memory=128Mi` and limits `cpu=200m, memory=256Mi` — all from the LimitRange, even though the manifest set nothing.
- `pod-only-cpu` keeps its cpu values and gains memory `request=128Mi / limit=256Mi`.
- `pod-only-memory` keeps its memory values and gains cpu `request=100m / limit=200m`.

Running totals after these 4 Pods (all inside the quota):

| | requests | limits |
|---|---|---|
| cpu    | 600m of 1000m  | 1100m of 2000m |
| memory | 768Mi of 2Gi   | 1536Mi of 4Gi  |
| pods   | 4 of 6         | — |

### Step 4 — Apply the Pods that fail (watch enforcement)

```bash
kubectl apply -f fail01.yml   # memory limit 10Gi  > LimitRange max 512Mi
kubectl apply -f fail02.yml   # cpu limit 1 (1000m) > LimitRange max 500m
kubectl apply -f fail03.yml   # cpu req 2 & mem req 3Gi > LimitRange max (500m/512Mi)
```

Each is rejected at admission with a `Forbidden` error, e.g.:

```
Error from server (Forbidden): error when creating "fail01.yml":
pods "pod-memory-fail" is forbidden:
maximum memory usage per Container is 512Mi, but limit is 10Gi
```

Note: all three of these trip the **LimitRange `max`** first (the `max` ceiling
applies to both requests and limits). `fail03` would *also* blow the ResourceQuota
(`requests.cpu: 1`, `requests.memory: 2Gi`), but with the LimitRange in place it
never gets that far.

---

## Seeing the ResourceQuota reject something (optional)

Because every failing Pod above is caught by the LimitRange first, here are two ways
to trigger a **quota** rejection specifically:

**Option A — exceed a cumulative cap.** After Step 3, keep creating small Pods until
`requests.cpu` passes 1000m. For example, re-applying `pod-full`-style Pods (300m
request each) a few times will eventually be refused with a `exceeded quota` message
while each Pod still individually satisfies the LimitRange.

**Option B — remove the LimitRange, then apply `fail03`.**

```bash
kubectl delete limitrange default-limits -n rq-demo
kubectl apply -f fail03.yml
# Now rejected by the quota:
#   exceeded quota: compute-quota, requested: requests.cpu=2,requests.memory=3Gi,
#   used: ..., limited: requests.cpu=1,requests.memory=2Gi
```

(Reapply `LimitRange.yml` afterward if you want to continue the main demo.)

---

## Handy checks

```bash
kubectl get pods -n rq-demo
kubectl describe resourcequota compute-quota -n rq-demo
kubectl describe limitrange default-limits -n rq-demo
```

## Cleanup

```bash
kubectl delete namespace rq-demo
```

Deleting the namespace removes every Pod, the LimitRange, and the ResourceQuota in one go.

---

## Key takeaways

- A **LimitRange** *mutates* Pods (filling in `default` / `defaultRequest`) and
  *validates* them against `min` / `max` per container.
- A **ResourceQuota** validates the *sum* across the whole namespace and, once set on
  `requests.*` / `limits.*`, forces every Pod to have those values — which the
  LimitRange defaults conveniently provide.
- When both exist, the LimitRange per-container checks are what an oversized single
  Pod hits first; the quota is what a *fleet* of otherwise-valid Pods hits.
