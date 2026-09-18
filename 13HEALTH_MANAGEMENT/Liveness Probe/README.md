# Kubernetes Liveness Probe — Hands-On Demo

A minimal demo that shows how a **liveness probe** works: when the probe fails,
Kubernetes decides the container is broken and **restarts it**.

```
Liveness  →  controls RESTART  (is this container still alive, or should it be killed?)
```

---

## What this demo teaches

A **liveness probe** answers one question for Kubernetes: *"Is this container still alive?"*

- Kubernetes runs the check repeatedly.
- If it **fails**, Kubernetes assumes the container is stuck/dead, **kills it, and restarts
  it** — the `RESTARTS` counter goes up.
- Use it for things a restart can fix: deadlocks, hung processes, wedged states.

This demo uses an **exec** probe: it succeeds only when the command exits `0`.
The command is `cat /tmp/live`, and a `postStart` hook creates `/tmp/live` when the
container starts. So deleting that file makes the probe fail — an easy way to *simulate a
crashed app* without actually crashing anything.

Because the same `postStart` hook re-runs on every restart, the container **recreates
`/tmp/live` and recovers on its own** after each restart.

---

## Files in this repo

| File       | What it is                                                                 |
|------------|---------------------------------------------------------------------------|
| `pod.yml`  | A single `nginx` Pod (`liveness-pod`) with a liveness probe. A `postStart` hook creates `/tmp/live` and a simple index page. |
| `steps`    | The raw command list this README is built from.                           |

> **Timing:** the probe uses `initialDelaySeconds: 5` and `periodSeconds: 5`, so wait a few
> seconds after breaking the app before expecting to see the restart.

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

### 2. Apply the manifests
```bash
kubectl apply -f .
```
This applies every YAML in the current directory (here, `pod.yml`).

### 3. Check the pod
```bash
kubectl get pod -n canary-demo
```
Expected:
```
NAME           READY   STATUS    RESTARTS   AGE
liveness-pod   1/1     Running   0          ...
```

### 4. Verify the app responds
```bash
kubectl exec -n canary-demo liveness-pod -- curl -s localhost
```
Expected:
```
Hello from Liveness Pod
```

### 5. Break the application (make the liveness probe fail)
```bash
kubectl exec -n canary-demo liveness-pod -- rm /tmp/live
```

### 6. Watch the pod restart
```bash
kubectl get po -n canary-demo -w
```
Expected — within a few probe cycles the restart counter climbs:
```
NAME           READY   STATUS    RESTARTS   AGE
liveness-pod   1/1     Running   1          ...
```
(Press `Ctrl+C` to stop watching.)

> ✅ **Lesson:** deleting `/tmp/live` made the liveness probe fail, so Kubernetes killed and
> restarted the container. On restart, the `postStart` hook recreated `/tmp/live`, the probe
> passed again, and the pod returned to `1/1 Running`.

---

## Key takeaway

```
Liveness probe fails  →  container is killed and restarted.
```

- Liveness is about **recovering a broken container**, not about routing traffic.
- Be careful in real workloads: a liveness probe that's too aggressive (too short a period,
  or checking something slow) can cause **restart loops**. Give the app enough
  `initialDelaySeconds` to start up.

---

## Cleanup

```bash
kubectl delete ns canary-demo
```
This removes the pod and the namespace in one go.
