# Kubernetes Liveness vs Readiness Probes — Hands-On Demo

A small, self-contained demo that shows **exactly** how Kubernetes treats the two
health probes differently, by breaking each one on purpose and watching what happens.

```
Readiness  →  controls TRAFFIC   (should this pod receive requests?)
Liveness   →  controls RESTART   (is this container still alive, or should it be killed?)
```

---

## What this demo teaches

Kubernetes uses **probes** to decide the state of a container. This demo focuses on the two
you'll use most often:

### Readiness probe — "Am I ready to serve traffic?"
- Kubernetes runs this check repeatedly.
- If it **fails**, the pod is marked `NOT READY` (`0/1`) and is **removed from the Service
  endpoints** — so it stops receiving traffic.
- The container is **NOT** restarted. It's still running; it just isn't sent requests.
- Use it for: warm-up time, waiting on a dependency (DB, cache), temporary overload.

### Liveness probe — "Am I still alive?"
- Kubernetes runs this check repeatedly.
- If it **fails**, Kubernetes assumes the container is stuck/dead and **restarts it**
  (the `RESTARTS` counter goes up).
- Use it for: deadlocks, hung processes, states a restart can fix.

### The key mental model

| Action                | Effect                          | Restart? |
|-----------------------|---------------------------------|----------|
| `rm /tmp/ready`       | Traffic stops (removed from Service) | ❌ No  |
| `rm /tmp/live`        | Container is killed and restarted    | ✅ Yes |

Both probes in this demo are **exec** probes: they succeed only if a command exits `0`.
Here the command is `cat /tmp/ready` / `cat /tmp/live`, so deleting the file makes the
probe fail — an easy way to simulate a broken app.

---

## Files in this repo

| File                   | What it is                                                        |
|------------------------|------------------------------------------------------------------|
| `both_health_probe.yml`| A single `nginx` Pod with **both** a liveness and a readiness probe. A `postStart` hook creates `/tmp/live`, `/tmp/ready`, and a simple index page. |
| `service.yml`          | A `NodePort` Service (`both-probes-service`) selecting `app: both`. |
| `steps`                | The raw command list this README is built from.                  |

> **Note:** The probes use `initialDelaySeconds` (10s liveness / 5s readiness) and
> `periodSeconds: 5`, so give the pod a few seconds after each change before expecting to
> see the effect.

---

## Prerequisites

- A running Kubernetes cluster (minikube, kind, Docker Desktop, or a real cluster).
- `kubectl` configured to talk to it.

---

## Steps

### 1. Create the namespace
```bash
kubectl create ns canary-demo
```

### 2. Create the Pod and Service
```bash
kubectl apply -f both_health_probe.yml
kubectl apply -f service.yml
```

### 3. Verify the pod is running
```bash
kubectl get pod -n canary-demo
```
Expected:
```
NAME              READY   STATUS    RESTARTS   AGE
both-probes-pod   1/1     Running   0          ...
```

### 4. Verify the app responds
```bash
kubectl exec -n canary-demo both-probes-pod -- curl -s localhost
```
Expected:
```
Hello from BOTH probes pod
```

---

### 5. Break READINESS (traffic should stop)
```bash
kubectl exec -n canary-demo both-probes-pod -- rm /tmp/ready
```

### 6. Watch the pod status change
```bash
kubectl get pod -n canary-demo -w
```
Expected — the pod becomes **not ready**, but is **not** restarted:
```
READY      0/1
RESTARTS   0
```
(Press `Ctrl+C` to stop watching.)

### 7. Confirm it was removed from the Service endpoints
```bash
kubectl get endpoints both-probes-service -n canary-demo
```
Expected — no endpoints, i.e. no traffic will reach the pod:
```
NAME                  ENDPOINTS   AGE
both-probes-service   <none>      ...
```

> ✅ **Lesson:** Readiness failing pulled the pod out of the Service. The container kept
> running the whole time.

---

### 8. Break LIVENESS (container should restart)
```bash
kubectl exec -n canary-demo both-probes-pod -- rm /tmp/live
```

### 9. Watch the pod restart
```bash
kubectl get pod -n canary-demo -w
```
Expected — the restart counter increases:
```
RESTARTS   1
```

### 10. Verify recovery
```bash
kubectl get pod -n canary-demo
kubectl get endpoints both-probes-service -n canary-demo
```
Expected:
```
Pod back to 1/1 Running
Endpoints restored
```

> ✅ **Why it recovers:** the container's `postStart` hook re-runs on restart and recreates
> `/tmp/live` and `/tmp/ready`, so both probes pass again and the pod rejoins the Service.

---

## Final takeaways

```
rm /tmp/ready  →  Traffic stops, NO restart   →  Readiness controls TRAFFIC
rm /tmp/live   →  Container restarts           →  Liveness  controls RESTART
```

- A **not-ready** pod is healthy but temporarily out of rotation.
- A **liveness failure** is treated as a broken container and gets killed + restarted.
- Design real probes carefully: a too-aggressive liveness probe can cause restart loops,
  while a missing readiness probe can send traffic to a pod that isn't ready yet.

---

## Cleanup

```bash
kubectl delete ns canary-demo
```
This removes the pod, the service, and the namespace in one go.
