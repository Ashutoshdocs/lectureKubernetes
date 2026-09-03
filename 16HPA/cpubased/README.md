# Kubernetes HPA Practical — Autoscaling NGINX under Load

A small, self-contained demo that shows the **Horizontal Pod Autoscaler (HPA)**
in action: deploy NGINX, point an HPA at it, drive CPU up with a load generator,
and watch Kubernetes scale the pods out and back in.

```
                 CPU rises past 50%                 load stops
 load-generator ───────────────────▶  HPA  ──scale──▶ 1 → 5 pods ──scale──▶ back to 1
      (busybox wget loop)          (reads metrics-server)
```

---

## What's in this repo

| File | What it is |
|------|------------|
| `deployment.yaml` | NGINX Deployment with CPU/memory **requests** (required for HPA) and health probes. |
| `service.yaml` | `ClusterIP` Service (`nginx-hpa-svc`) that fronts the NGINX pods. |
| `hpa.yaml` | The HorizontalPodAutoscaler: target 50% CPU, scale 1→5, with tuned scale up/down behavior. |
| `generator.yaml` | A busybox pod that loops `wget` against the Service to create CPU load. |
| `setup.sh` | Installs and configures **metrics-server** (idempotent). |
| `cleanup.sh` | Removes the demo resources. |
| `Makefile` | Shortcuts: `make setup / deploy / load / watch / top / destroy`. |

---

## Prerequisites

- A running Kubernetes cluster (kubeadm, kind, minikube, k3s, or a managed cluster).
- `kubectl` configured to talk to it (`kubectl get nodes` works).
- **metrics-server** — installed for you by `setup.sh`. The HPA reads CPU/memory
  from it; without it the HPA target shows `<unknown>` and never scales.

> The scripts ship without the executable bit. Either run them with `bash setup.sh`,
> or make them executable once: `chmod +x setup.sh cleanup.sh`.

---

## Quick start

```bash
# 1. Install + configure metrics-server (waits until `kubectl top` works)
bash setup.sh          # or: make setup

# 2. Deploy the app + service + HPA
kubectl apply -f deployment.yaml -f service.yaml -f hpa.yaml   # or: make deploy

# 3. In a second terminal, watch things scale
watch -n 2 'kubectl get hpa nginx-hpa; echo; kubectl get pods -l app=nginx-hpa'   # or: make watch

# 4. Start generating load
kubectl apply -f generator.yaml    # or: make load

# 5. When you've seen it scale up, stop the load and watch it scale back down
kubectl delete -f generator.yaml   # or: make clean
```

Tear everything down when you're done:

```bash
bash cleanup.sh        # or: make destroy
```

---

## Step-by-step walkthrough

### 1. Install metrics-server

```bash
bash setup.sh
```

This installs metrics-server `v0.8.1`, patches in the two flags dev clusters need
(`--kubelet-insecure-tls` and `--kubelet-preferred-address-types`), restarts it,
and blocks until `kubectl top nodes` returns real numbers.

Verify by hand if you like:

```bash
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl top nodes
```

> Pin a different version: `METRICS_SERVER_VERSION=v0.9.0 bash setup.sh`
> (0.8.x supports Kubernetes 1.31+, 0.9.x supports 1.34+.)

### 2. Deploy NGINX, the Service, and the HPA

```bash
kubectl apply -f deployment.yaml -f service.yaml -f hpa.yaml
```

Confirm the HPA can read metrics — the `TARGETS` column should show a real
percentage (e.g. `1%/50%`), **not** `<unknown>/50%`:

```bash
kubectl get hpa nginx-hpa
```

Give metrics-server 15–30 seconds after deploying if it still shows `<unknown>`.

### 3. Watch it live

In a **separate** terminal:

```bash
watch -n 2 'kubectl get hpa nginx-hpa; echo; kubectl get pods -l app=nginx-hpa'
```

### 4. Generate load

```bash
kubectl apply -f generator.yaml
```

The busybox pod hammers `http://nginx-hpa-svc` in a tight loop. Within a minute
or two the HPA's `TARGETS` climbs above 50% and `REPLICAS` starts rising toward
the max of 5.

You can also watch raw usage:

```bash
kubectl top pods -l app=nginx-hpa
```

### 5. Scale back down

Stop the load:

```bash
kubectl delete -f generator.yaml
```

CPU falls, and after the scale-down stabilization window (60s in this demo) the
HPA trims replicas back toward 1.

---

## How the autoscaling math works

The HPA periodically compares **current CPU utilization** to the **target**, then
computes the desired replica count:

```
desiredReplicas = ceil( currentReplicas × (currentUtilization / targetUtilization) )
```

"Utilization" is measured against the container's CPU **request**, not its limit:

```
utilization = actualCpuUsage / cpuRequest
```

In this demo the request is `100m` and the target is `50%`, so the HPA aims to
keep each pod averaging about `50m` of CPU. Example: if 1 pod is averaging `150m`
(150% of its request), then `ceil(1 × (150 / 50)) = 3` pods — capped at
`maxReplicas: 5`.

That's why **resource requests are mandatory** for a CPU HPA: without a request,
there's no denominator and the target reads `<unknown>`.

---

## Tuning and customization

- **Thresholds / bounds** — edit `averageUtilization`, `minReplicas`,
  `maxReplicas` in `hpa.yaml`.
- **Scale on memory too** — uncomment the memory metric block in `hpa.yaml`. The
  HPA scales on whichever metric asks for the most replicas.
- **Reaction speed** — the `behavior` block controls how aggressively it scales.
  This demo uses a `0s` scale-up window (instant) and a shortened `60s` scale-down
  window (Kubernetes defaults to `300s`) so you don't wait five minutes to see it
  shrink.
- **More load** — one `wget` loop may not be enough on a beefy node. Scale the
  driver up: `kubectl scale --replicas=3 deploy/…` won't work on a bare Pod, so
  instead run several copies, e.g.
  `for i in 1 2 3; do kubectl run load-$i --image=busybox:1.36 --restart=Never -- /bin/sh -c 'while true; do wget -q -O- http://nginx-hpa-svc >/dev/null; done'; done`.

---

## Troubleshooting

**`TARGETS` shows `<unknown>/50%`**
Metrics aren't flowing. Check metrics-server:
```bash
kubectl top pods -l app=nginx-hpa
kubectl logs -n kube-system deployment/metrics-server
```
On dev clusters this is almost always the missing TLS/address flags — re-run
`bash setup.sh`.

**metrics-server pod is running but `kubectl top` errors**
The APIService may not be registered yet:
```bash
kubectl get apiservice v1beta1.metrics.k8s.io
```
Wait ~30–60s after install; it registers asynchronously.

**HPA won't scale up even under load**
- Confirm the Deployment has CPU **requests** (it does in `deployment.yaml`).
- Confirm load is actually hitting the Service: `kubectl logs load-generator`.
- Give it 1–2 minutes — the HPA polls on an interval, it isn't instant.

**HPA won't scale down**
Scale-down respects the stabilization window (60s here, 300s by default). Make
sure the load generator is actually deleted: `kubectl get pod load-generator`.

**Re-applying the Deployment resets replicas to 1**
Expected. `deployment.yaml` hard-codes `replicas: 1` as a starting point. Once the
HPA is in charge, avoid re-applying that field (or remove it from the file) so you
don't fight the autoscaler.

---

## Cleanup

```bash
bash cleanup.sh
```

This deletes the Deployment, Service, HPA, and load generator. It intentionally
leaves metrics-server installed (other workloads may use it). To remove that too:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
```

---

## What changed from the original setup

- **`setupCommands` → `setup.sh`** — a real script with `set -euo pipefail`, an
  idempotent patch (won't duplicate flags on re-run), and an automatic wait until
  metrics are actually available.
- **`deployment.yaml`** — added `readiness`/`liveness` probes, a named `http`
  port, `imagePullPolicy`, `revisionHistoryLimit`, standard labels, and inline
  notes on why requests matter for the HPA.
- **`service.yaml`** — named port + `targetPort: http`, labels, comments.
- **`hpa.yaml`** — added a `behavior` block for predictable, demo-friendly
  scaling, plus a ready-to-uncomment memory metric.
- **`generator.yaml`** — added resource limits, `restartPolicy: Never`, and a
  cleaner loop.
- Added **`cleanup.sh`** and a **`Makefile`** so the whole flow is a few short
  commands.
