# KEDA Scale-to-Zero Demo (Redis Queue)

A small, self-contained demo for **teaching KEDA** — Kubernetes Event-Driven Autoscaling. A worker Deployment sits idle at **zero replicas** until tasks pile up in a Redis list. KEDA notices the queue growing, scales the workers **up to 10**, they drain the queue, and KEDA scales them **back to zero**. You watch the whole cycle happen live.

This is the classic "scale on a queue" pattern — the thing plain Kubernetes autoscaling (HPA on CPU/memory) can't do well, because HPA can't scale to zero and doesn't understand queue depth.

## What You'll Learn

- What a **ScaledObject** is and how it connects a workload to an event source.
- **Scale-to-zero**: why it matters and how KEDA does it (the part HPA can't).
- The division of labour: **KEDA handles 0<->1, an HPA handles 1<->N.**
- How queue length turns into a replica count (the scaling math).
- How to observe scaling decisions in real time and debug them.

## How KEDA Works (the 60-second version)

Plain Kubernetes gives you the **HorizontalPodAutoscaler (HPA)**, which scales on CPU/memory and has a floor of 1 replica. KEDA extends this in two ways:

1. **External triggers (scalers).** KEDA ships 60+ scalers (Redis, Kafka, RabbitMQ, SQS, Prometheus, cron, ...) that read a metric from outside the cluster — here, the length of a Redis list.
2. **Scale-to-zero.** KEDA can activate a workload from **0 -> 1** and deactivate it from **1 -> 0**, which a raw HPA cannot.

When you apply a **ScaledObject**, KEDA:

- Watches the trigger every `pollingInterval` seconds.
- **Activates** the target (0 -> 1) as soon as the metric crosses the activation threshold.
- Creates a hidden HPA named `keda-hpa-<scaledobject-name>` that owns scaling from **1 -> N**.
- **Deactivates** the target (-> 0) once the metric stays below target for `cooldownPeriod` seconds.

```
                 poll every 5s
   Redis "tasks"  ------------->  KEDA operator
   (LLEN = queue depth)                |
                                       |-- 0->1 / 1->0   (KEDA does this)
                                       |
                                       +-- creates HPA -- 1->N  (HPA does this)
                                                            |
                                                            v
                                                    worker Deployment
                                                    (0 ... 10 replicas)
```

## Architecture of This Demo

```
 +------------+     LPUSH tasks       +--------------+
 |  you /     | --------------------> |    Redis     |
 | load-tasks |                       |  list: tasks |
 +------------+                       +------+-------+
                                             | LLEN (polled by KEDA)
                                             v
                                      +--------------+
                                      | ScaledObject |  keda.sh/v1alpha1
                                      | worker-scaler|  min=0 max=10 target=5/replica
                                      +------+-------+
                                             | drives
                                             v
                                      +--------------+   each pod: LPOP tasks
                                      |   worker     |   in a loop
                                      |  Deployment  |   0 ... 10 replicas
                                      +--------------+
```

## Repository Contents

| File | Purpose |
|------|---------|
| `redis.yaml` | Redis Deployment + Service — the task queue |
| `worker.yaml` | Worker Deployment (starts at `replicas: 0`) that pops tasks |
| `scaleobject.yaml` | The KEDA `ScaledObject` — the star of the show |
| `load-tasks.sh` | Push N tasks onto the queue to trigger scale-up |
| `watch-scaling.sh` | Live dashboard: queue length, replicas, HPA, pods |
| `COMMANDS` | Raw command history (KEDA install + load) |

## Prerequisites

- A running Kubernetes cluster. Any of these is fine:
  - **kind**: `kind create cluster --name keda-demo`
  - **minikube**: `minikube start`
  - Docker Desktop's built-in Kubernetes
- `kubectl` configured to talk to it (`kubectl get nodes` works).
- `helm` (v3+). The `COMMANDS` file installs it; or use your package manager.

## Step-by-Step
### 0 install helm
``` bash
sudo apt-get update
sudo apt-get install -y curl gpg apt-transport-https

curl https://baltocdn.com/helm/signing.asc | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/helm.gpg > /dev/null

echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/usr/share/keyrings/helm.gpg] \
https://baltocdn.com/helm/stable/debian/ all main" | \
  sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

sudo apt-get update
sudo apt-get install -y helm
```
### 1. Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace

# Wait until the KEDA operator, metrics-apiserver, and admission-webhooks are Running:
kubectl get pods -n keda -w
```

### 2. Deploy Redis, the worker, and the ScaledObject

Apply Redis first (so the queue exists before workers try to connect), then the worker, then the scaler:

```bash
kubectl apply -f redis.yaml
kubectl rollout status deploy/redis      # wait for Redis to be ready

kubectl apply -f worker.yaml
kubectl apply -f scaleobject.yaml
```

### 3. Confirm you're scaled to zero

This is the first "aha": the worker exists but runs **no pods**.

```bash
kubectl get scaledobject worker-scaler
# READY=True, ACTIVE=False  -> KEDA is watching, but the queue is empty

kubectl get deploy worker
# READY 0/0  -> scaled to zero, consuming no CPU/memory

kubectl get pods -l app=worker
# No resources found  -> literally nothing running
```

Notice KEDA also created an HPA for you:

```bash
kubectl get hpa
# keda-hpa-worker-scaler ... targets: <unknown>/5 (or 0/5)
```

### 4. Generate load and watch it scale up

Open a second terminal for the live dashboard:

```bash
chmod +x watch-scaling.sh load-tasks.sh   # first time only
./watch-scaling.sh
```

In the first terminal, push 50 tasks:

```bash
./load-tasks.sh 50
# equivalent to:
# for i in $(seq 1 50); do kubectl exec deploy/redis -- redis-cli LPUSH tasks task$i; done
```

Within a poll interval or two you'll see:

- `ScaledObject` **ACTIVE** flips to `True`.
- `worker` deployment climbs `0 -> ... -> 10`.
- The HPA shows `targets: 50/5` then the replica count rising.

Tail a worker's logs to see tasks being processed:

```bash
kubectl logs -l app=worker --tail=20 -f
```

### 5. Watch it drain and scale to zero

Do nothing. The 10 workers `LPOP` tasks until the list is empty. Once the queue stays empty for `cooldownPeriod` (30s), KEDA scales the deployment back to **0**. The dashboard will walk `10 -> ... -> 0`.

That full round trip — **0 -> 10 -> 0, driven entirely by queue depth** — is the lesson.

## The Scaling Math

The Redis-list scaler targets **`listLength` items per replica**:

```
desiredReplicas = ceil( currentQueueLength / listLength )
                = ceil( LLEN(tasks)        / 5           )
```

| Queue length | Calculation | Desired replicas |
|-------------:|-------------|-----------------:|
| 0 | — | 0 (after cooldown) |
| 1 | ceil(1/5) | 1 |
| 5 | ceil(5/5) | 1 |
| 12 | ceil(12/5) | 3 |
| 50 | ceil(50/5) | 10 |
| 200 | ceil(200/5) = 40 | **10** (capped by `maxReplicaCount`) |

So `listLength` is really a **target backlog per pod**: smaller = more aggressive scaling, larger = more work per pod before adding another.

## Key Concepts, Mapped to the Files

- **ScaledObject** (`scaleobject.yaml`) — the CRD that says "scale *this* target based on *these* triggers." `scaleTargetRef` points at the worker Deployment.
- **minReplicaCount: 0** — enables scale-to-zero. This single line is the difference from a plain HPA.
- **pollingInterval / cooldownPeriod** — kept short (5s / 30s) so the demo reacts quickly. Production values are usually higher.
- **listLength** — target queue depth per replica (see the math above).
- **activationListLength** (commented out) — the **0 -> 1 threshold**, handled by KEDA itself, separate from the HPA's 1 -> N target. Set it to `"5"` and the app *won't wake up* until the queue exceeds 5, which prevents flapping on tiny bursts. Great to demo the activation-vs-scaling distinction.
- **The generated HPA** (`keda-hpa-worker-scaler`) — proof that KEDA delegates 1 -> N scaling to normal Kubernetes machinery. You never write this HPA yourself.

## Experiments to Try

Good prompts for a class or a self-study session:

1. **Make it snappier or lazier.** Change `listLength` to `"1"` (one pod per task, up to the cap) or `"25"` (only 2 pods for 50 tasks). Re-apply and reload.
2. **Prevent flapping.** Uncomment `activationListLength: "5"`, push just 3 tasks, and watch it *stay at zero*. Then push 10.
3. **Hit the ceiling.** Push 500 tasks and confirm it caps at `maxReplicaCount: 10`, not 100.
4. **Slow the workers.** Increase the `sleep` in `worker.yaml` so the queue drains slowly — the deployment holds at 10 longer, making scale-down easier to observe.
5. **Read the HPA's view.** `kubectl describe hpa keda-hpa-worker-scaler` to see the metric it's reacting to and its scaling events.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `ScaledObject` READY=False | KEDA can't reach Redis. Check the `address` and that Redis is Running: `kubectl get pods -l app=redis`. |
| Worker never scales up | Confirm ACTIVE flips: `kubectl get scaledobject worker-scaler`. Check KEDA operator logs: `kubectl logs -n keda -l app=keda-operator`. |
| Stuck at 1 replica, won't reach 0 | You still have items in the list, or you're inside `cooldownPeriod`. Check `kubectl exec deploy/redis -- redis-cli LLEN tasks`. |
| Pods scheduled but Pending | Not enough cluster capacity for 10 replicas. The tiny resource requests in `worker.yaml` should prevent this on most laptops. |
| Editing `replicas` by hand does nothing | Expected — once a ScaledObject targets a Deployment, KEDA owns the replica count. |

## Cleanup

```bash
kubectl delete -f scaleobject.yaml
kubectl delete -f worker.yaml
kubectl delete -f redis.yaml

# Remove KEDA itself:
helm uninstall keda -n keda
kubectl delete namespace keda

# If you spun up a throwaway cluster:
# kind delete cluster --name keda-demo    # or: minikube delete
```

## References

- KEDA docs — https://keda.sh/docs/
- KEDA Redis Lists scaler — https://keda.sh/docs/latest/scalers/redis-lists/
- ScaledObject spec — https://keda.sh/docs/latest/concepts/scaling-deployments/
- Kubernetes HPA — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
