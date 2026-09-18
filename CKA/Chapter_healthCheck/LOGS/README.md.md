# Kubernetes Multi-Container Pod, NodePort & Logging — Hands-On Demo

A frontend pod running **two web containers** that are **both reachable from outside the
cluster** through a single NodePort Service — plus the **production log commands** you'll
actually reach for when debugging pods.

```
web-nginx   (container 1)  →  nginx  :80    →  nodePort 30080
web-python  (container 2)  →  python :8080  →  nodePort 30081
```

---

## What this demo teaches

Three things that come up constantly in real clusters:

### 1. Multiple containers in one pod
A pod can run more than one container. They **share the same network namespace**, so they
talk to each other over `localhost` and each just needs a **different port**. Here one pod
runs an NGINX server (`:80`) and a Python HTTP server (`:8080`).

### 2. Exposing more than one container port via NodePort
A single Service can publish **several ports**, each mapping a container port to its own
`nodePort`. That's how both containers become reachable from outside the cluster at once —
no second Service required.

### 3. Reading logs like you would in production
`kubectl logs` is the first tool you reach for when something misbehaves. In a
**multi-container** pod you *must* say **which container** with `-c`, and there are a handful
of flags (`-f`, `--tail`, `--since`, `--previous`, `--timestamps`) that separate a quick
guess from real debugging. Both containers here are set up so **every HTTP request produces
a log line**, so you can watch traffic land live.

> Why these images log usefully: the official **nginx** image symlinks its access/error logs
> to `stdout`/`stderr`, and Python's `http.server` prints every request to `stderr`. Kubernetes
> captures a container's stdout/stderr, which is exactly what `kubectl logs` reads.

---

## Files in this repo

| File          | What it is                                                                 |
|---------------|---------------------------------------------------------------------------|
| `pod.yml`     | `frontend-pod` with two containers: `web-nginx` (:80) and `web-python` (:8080). |
| `service.yml` | `NodePort` Service `frontend-service` publishing both ports (30080, 30081). |

---

## Prerequisites

- A running Kubernetes cluster (minikube, kind, Docker Desktop, or a real cluster).
- `kubectl` configured to talk to it.

---

## Setup

### 1. Create the namespace
```bash
kubectl create ns logs-demo
```

### 2. Apply the pod and the Service
```bash
kubectl apply -f pod.yml
kubectl apply -f service.yml
```

### 3. Wait for the pod to be ready (both containers)
```bash
kubectl get pod frontend-pod -n logs-demo -w
```
Expected — `READY 2/2` means both containers are up:
```
NAME           READY   STATUS    RESTARTS   AGE
frontend-pod   2/2     Running   0          ...
```
(Press `Ctrl+C` to stop watching.)

### 4. Confirm the Service publishes both ports
```bash
kubectl get svc frontend-service -n logs-demo
```
```
PORT(S)                       →  80:30080/TCP, 8080:30081/TCP
```

---

## Reach both containers from outside the cluster

Get a node IP (`kubectl get nodes -o wide`), then:

```bash
curl http://<NodeIP>:30080     # container 1 → "Frontend - NGINX (container 1) :80"
curl http://<NodeIP>:30081     # container 2 → "Frontend - Python (container 2) :8080"
```

> **minikube:** node ports aren't always directly reachable. Use the tunnels:
> ```bash
> minikube service frontend-service -n logs-demo --url
> ```
> It prints one URL per published port — the first is nginx, the second is python.

Send a few requests to each so there's something in the logs for the next section.

---

## Production log commands

The core rule for this pod: it has **two containers**, so nearly every command needs
`-c <container>` (`web-nginx` or `web-python`). Without `-c`, `kubectl` errors and lists the
container names.

### Tail logs live (the everyday one)
Follow a container's logs in real time — run this, then curl the port in another terminal and
watch requests appear:
```bash
kubectl logs -f frontend-pod -c web-nginx  -n logs-demo
kubectl logs -f frontend-pod -c web-python -n logs-demo
```

### Only the recent lines
Don't dump the whole history — grab the tail:
```bash
kubectl logs frontend-pod -c web-nginx -n logs-demo --tail=50
```

### Logs within a time window
```bash
kubectl logs frontend-pod -c web-python -n logs-demo --since=10m
kubectl logs frontend-pod -c web-nginx  -n logs-demo --since=1h
```

### Add timestamps
Useful when correlating across containers or services:
```bash
kubectl logs frontend-pod -c web-nginx -n logs-demo --timestamps
```

### Logs from a CRASHED / restarted container
When a container has restarted, this shows the logs from the **previous** instance — often
where the actual cause of a crash is:
```bash
kubectl logs frontend-pod -c web-python -n logs-demo --previous
```

### All containers at once
Prefix each line with the container name (great for a quick overview):
```bash
kubectl logs frontend-pod -n logs-demo --all-containers=true --prefix=true
```

### Follow + tail together (common live-debug combo)
```bash
kubectl logs -f --tail=20 frontend-pod -c web-nginx -n logs-demo
```

### Logs by label instead of pod name
In real clusters you rarely know the exact pod name — select by label:
```bash
kubectl logs -l app=frontend -n logs-demo --all-containers=true --tail=100 --prefix=true
```

---

## Handy companions to `kubectl logs`

**Live events for the whole namespace** (scheduling, pulls, restarts, OOMKills):
```bash
kubectl get events -n logs-demo --sort-by=.lastTimestamp
```

**Describe the pod** — probe results, restart reasons, container states:
```bash
kubectl describe pod frontend-pod -n logs-demo
```

**Exec into a specific container** to poke around:
```bash
kubectl exec -it frontend-pod -c web-nginx -n logs-demo -- sh
```

---

## Quick reference

| Goal                         | Command                                                                 |
|------------------------------|-------------------------------------------------------------------------|
| Live tail                    | `kubectl logs -f frontend-pod -c web-nginx -n logs-demo`               |
| Last N lines                 | `... --tail=50`                                                         |
| Time window                  | `... --since=10m`                                                       |
| With timestamps              | `... --timestamps`                                                      |
| Previous (crashed) instance  | `... --previous`                                                        |
| All containers, prefixed     | `kubectl logs frontend-pod -n logs-demo --all-containers --prefix`     |
| By label                     | `kubectl logs -l app=frontend -n logs-demo --all-containers --tail=100`|

---

## Key takeaways

- One pod can host **multiple containers** that share `localhost` and differ by **port**.
- A **single NodePort Service** can expose **several ports**, making each container reachable
  from outside the cluster.
- In a multi-container pod, **`kubectl logs` needs `-c <container>`**.
- Real debugging leans on `-f`, `--tail`, `--since`, `--previous`, `--timestamps`,
  `--all-containers`, and selecting **by label** rather than by pod name.

---

## Cleanup

```bash
kubectl delete ns logs-demo
```
This removes the pod, the Service, and the namespace in one go.
