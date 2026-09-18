# Memory-Based Horizontal Pod Autoscaler (HPA) Demo

A small, self-contained demo that scales a Deployment **up and down based on memory usage**.
A tiny Python app allocates memory on demand, a load generator drives that allocation, and a
`HorizontalPodAutoscaler` reacts to the resulting memory pressure.

Unlike a naive "allocate forever" demo, this one is built to actually be practical:

- **Memory decays** (TTL) so the app scales **back in** when load stops — not just out.
- A **safety ceiling** keeps pods under their memory limit, so they never get **OOMKilled**
  mid-demo.
- **Readiness/liveness probes**, a dedicated **namespace**, and explicit **HPA scale-up/down
  behavior** so the demo is stable and repeatable.

---

## How memory-based HPA works (the one thing to understand)

The HPA target is a **percentage of the pod's memory `request`**, averaged across all running
pods — *not* the limit, and *not* raw MiB:

```
desiredReplicas = ceil( currentReplicas * ( currentAvgMemory / targetMemory ) )
targetMemory    = averageUtilization% * memory.request
```

In this demo: `request = 128Mi`, `target = 70%`, so the HPA aims to keep the **average memory
per pod near ~90Mi**. When the average climbs above that it adds pods; sustained below it, it
removes them.

> Memory is a *non-compressible* resource. A pod can't be throttled on memory the way it can on
> CPU — if it exceeds its limit it gets OOMKilled. That's why this app caps itself (`MAX_MB`)
> and lets memory expire (`TTL_SECONDS`).

---

## Prerequisites

- A running Kubernetes cluster (`kubectl` pointed at it).
- **metrics-server installed and healthy** — this is what feeds memory data to the HPA. Without
  it the HPA shows `<unknown>` and never scales.

Check it:

```bash
kubectl top pods -A            # should print numbers, not an error
kubectl get deploy -n kube-system metrics-server
```

Install it if missing:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

On local clusters (kind / minikube / k3s) metrics-server often needs `--kubelet-insecure-tls`.
For minikube the simplest path is `minikube addons enable metrics-server`.

---

## Files

| File | What it is |
|------|------------|
| `00-namespace.yaml`      | `hpa-demo` namespace |
| `01-configmap.yaml`      | The Python app (self-decaying memory, `/load` `/clear` `/status` `/healthz`) |
| `02-deployment.yaml`     | App Deployment with probes, env config, requests/limits |
| `03-service.yaml`        | ClusterIP Service on port 80 → 8080 |
| `04-hpa.yaml`            | Memory HPA (70% of request, 1–5 replicas, scale behavior) |
| `05-load-generator.yaml` | Scalable load generator Deployment |

---

## Quick start

```bash
# Apply everything in order
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap.yaml
kubectl apply -f 02-deployment.yaml
kubectl apply -f 03-service.yaml
kubectl apply -f 04-hpa.yaml

# Confirm the app is up before starting load
kubectl -n hpa-demo rollout status deploy/memory-hpa
```

In one terminal, watch the HPA and pods:

```bash
watch -n 2 kubectl -n hpa-demo get hpa,pods
```

In another, start the load:

```bash
kubectl apply -f 05-load-generator.yaml
```

Within ~30–60s you should see `TARGETS` climb past `70%` and `REPLICAS` grow toward 3–5.

---

## Watch it scale back in

Stop the load and memory decays over `TTL_SECONDS` (60s), so the HPA scales down after its
`scaleDown` stabilization window (120s):

```bash
kubectl -n hpa-demo scale deploy/memory-load-generator --replicas=0
# or: kubectl delete -f 05-load-generator.yaml
```

You'll see average memory fall, then replicas step back down to `1` (one pod removed per 60s).

---

## Useful commands

```bash
# Live HPA detail (events explain every scale decision)
kubectl -n hpa-demo describe hpa memory-hpa

# Per-pod memory
kubectl -n hpa-demo top pods

# Poke the app directly
kubectl -n hpa-demo run curl --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -q -O- http://memory-hpa-svc/status

# Push more load without editing files
kubectl -n hpa-demo scale deploy/memory-load-generator --replicas=3

# Manually free memory on the pod you hit (round-robins via the Service)
kubectl -n hpa-demo run curl --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -q -O- http://memory-hpa-svc/clear
```

---

## Tuning

Adjust the env vars in `02-deployment.yaml` and the target in `04-hpa.yaml`:

| Knob | Where | Effect |
|------|-------|--------|
| `CHUNK_MB`            | deployment env | MiB added per `/load` hit |
| `TTL_SECONDS`         | deployment env | How long each chunk is held before auto-free (controls scale-down speed) |
| `MAX_MB`              | deployment env | Per-pod ceiling; keep it well below the memory **limit** |
| `memory.request`      | deployment      | Denominator for the HPA %; lower it to trigger scaling sooner |
| `memory.limit`        | deployment      | Hard cap; OOMKill happens above this |
| `averageUtilization`  | hpa             | Target % of the request |
| `min/maxReplicas`     | hpa             | Scaling bounds |
| load generator `replicas` / `sleep` | load gen | Total load driven at the Service |

**Rough steady state** with the defaults: the load generator adds `5Mi` every `2s`, and each
chunk lives `60s`, so total live memory across all pods settles around `~150Mi`. Spread over 2–3
pods (plus ~20–25Mi interpreter overhead each) that lands near the 70% target, so the demo
typically settles around **2–3 replicas** under steady load and returns to **1** when load stops.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|--------|--------------------|
| HPA `TARGETS` shows `<unknown>` | metrics-server missing/unhealthy. `kubectl top pods -A`. |
| Never scales up | Load not reaching pods (`kubectl -n hpa-demo logs deploy/memory-load-generator`), or request set too high. |
| Pods restart with `OOMKilled` | `MAX_MB` too close to the memory **limit**; lower `MAX_MB` or raise the limit. |
| Scales up but never down | Expected to take `TTL_SECONDS` + `scaleDown` window (~3 min total). Be patient, or `--replicas=0` the load gen. |
| Metrics lag ~15–60s | Normal — metrics-server samples on an interval and HPA syncs ~every 15s. |

---

## Cleanup

```bash
kubectl delete namespace hpa-demo
```

---

## Notes and caveats

- **Memory HPA is coarser than CPU HPA.** Metrics are sampled on an interval and memory doesn't
  change as instantly as CPU, so expect lag and some steppiness — that's inherent, not a bug.
- Because the app holds memory **per pod in-process** and the Service round-robins, newly added
  pods start empty; the average is what the HPA acts on, and the TTL is what makes the whole
  thing converge instead of ratcheting to `maxReplicas` and OOMKilling.
- In production, prefer scaling on a metric that reflects real work (requests/sec, queue depth
  via custom/external metrics) over raw memory, since memory pressure is often a symptom rather
  than the signal you actually want to scale on.
