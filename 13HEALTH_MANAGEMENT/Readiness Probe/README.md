# Kubernetes Readiness Probe & Traffic Routing — Hands-On Demo

A demo with **two pods behind one Service** that shows how a **readiness probe**
decides which pods receive traffic. By breaking and fixing readiness on each pod, you can
watch the Service route requests only to the pods that are ready.

```
Readiness  →  controls TRAFFIC  (should this pod be in the Service and receive requests?)
```

---

## What this demo teaches

A **readiness probe** answers one question for Kubernetes: *"Is this pod ready to serve
requests right now?"*

- Kubernetes runs the check repeatedly.
- If it **fails**, the pod is marked `NOT READY` (`0/1`) and is **removed from the Service's
  endpoints** — so it stops receiving traffic.
- The container is **NOT** restarted. It keeps running; it's just taken out of rotation.
- When the probe **passes again**, the pod is added back to the endpoints and starts
  receiving traffic once more.

With **two pods** (`pod-1` and `pod-2`) behind one Service (`hello-service`), this becomes a
live load-balancing experiment:

- Both ready → traffic is split across both.
- Break one → traffic goes only to the other.
- Break both → the Service has no endpoints and requests fail.
- Fix one → traffic flows to it again.

This is exactly the mechanism behind rolling updates and canary/blue-green style traffic
control: **only ready pods get traffic.**

The probes here are **exec** probes (`cat /tmp/ready`), and a `postStart` hook creates
`/tmp/ready` at startup. Deleting the file makes the probe fail; recreating it makes the
probe pass — a simple way to simulate a pod going in and out of service.

---

## Files in this repo

| File          | What it is                                                              |
|---------------|------------------------------------------------------------------------|
| `pod01.yml`   | Pod `pod-1` (`nginx`, label `app: hello`) with a readiness probe, serving "Hello from Pod-1". |
| `pod2.yml`    | Pod `pod-2` (`nginx`, label `app: hello`) with a readiness probe, serving "Hello from Pod-2". |
| `service.yml` | `NodePort` Service `hello-service` selecting `app: hello` (so it targets both pods). |
| `steps`       | The raw command list this README is built from.                        |

> Both pods share the label `app: hello`, which is how the Service's selector picks them up.
> The distinct index pages ("Pod-1" vs "Pod-2") let you tell which pod answered a request.

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

### 2. Apply both pods
```bash
kubectl apply -f pod01.yml -n canary-demo
kubectl apply -f pod2.yml -n canary-demo
```

### 3. Apply the Service
```bash
kubectl apply -f service.yml -n canary-demo
```

### 4. Verify the pods
```bash
kubectl get pods -n canary-demo
```
Expected — both ready after the initial delay:
```
NAME    READY   STATUS    RESTARTS   AGE
pod-1   1/1     Running   0          ...
pod-2   1/1     Running   0          ...
```

### 5. Verify the Service
```bash
kubectl get svc -n canary-demo
```
Note the `NodePort` (the `80:PORT/TCP` value) — you'll use it in the curl commands.

### 6. Test the Service
```bash
curl http://<NodeIP>:<NodePort>
```
Repeat it a few times — you should see responses from **both** "Hello from Pod-1" and
"Hello from Pod-2" as the Service load-balances.

> **Tip (minikube):** get a reachable URL with
> `minikube service hello-service -n canary-demo --url`.

---

### 7. Break pod-2 readiness
```bash
kubectl exec -n canary-demo pod-2 -- rm /tmp/ready
```

### 8. Check readiness state
```bash
kubectl get pods -n canary-demo
```
Expected — `pod-2` drops out, `RESTARTS` stays `0`:
```
NAME    READY   STATUS    RESTARTS   AGE
pod-1   1/1     Running   0          ...
pod-2   0/1     Running   0          ...
```

### 9. Curl again — only pod-1 answers
```bash
curl http://<NodeIP>:<NodePort>
```
Every response is now "Hello from Pod-1". `pod-2` is still running but out of the Service.

---

### 10. Break pod-1 readiness (now both are down)
```bash
kubectl exec -n canary-demo pod-1 -- rm /tmp/ready
```

### 11. Fix pod-2 readiness
```bash
kubectl exec -n canary-demo pod-2 -- sh -c "echo ready > /tmp/ready"
```

### 12. Check readiness states
```bash
kubectl get pods -n canary-demo
```
Expected — the roles have flipped:
```
pod-1   0/1   Running
pod-2   1/1   Running
```

### 13. Curl again — only pod-2 answers
```bash
curl http://<NodeIP>:<NodePort>
```
Every response is now "Hello from Pod-2".

### 14. Fix pod-1 readiness (back to both ready)
```bash
kubectl exec -n canary-demo pod-1 -- sh -c "echo ready > /tmp/ready"
```
After a probe cycle, both pods are `1/1` again and traffic is split across both.

> ✅ **Lesson:** you never restarted anything. Traffic followed readiness — each pod entered
> and left the Service purely based on whether `/tmp/ready` existed.

---

## Useful debugging commands

These map to the remaining steps and are handy for inspecting what's going on.

**Curl from inside a pod** (bypasses the Service):
```bash
kubectl exec -n canary-demo pod-2 -- curl -s localhost
```

**Inspect the Service's live endpoints** — the clearest view of who's receiving traffic:
```bash
kubectl get endpoints hello-service -n canary-demo -o wide
```
Only **ready** pods appear here. Break a pod's readiness and its IP disappears from the list.

**View a pod's served page:**
```bash
kubectl exec -n canary-demo pod-2 -- cat /usr/share/nginx/html/index.html
```

**Describe a pod** to see probe events and why it's not ready:
```bash
kubectl describe pod pod-2 -n canary-demo
```
Look at the `Events` and `Conditions` sections — `Readiness probe failed` shows up here.

**Open a shell inside a pod:**
```bash
kubectl exec -it -n canary-demo pod-1 -- sh
```

---

## Key takeaways

```
Readiness passes  →  pod is in the Service endpoints  →  receives traffic
Readiness fails   →  pod is removed from endpoints     →  no traffic, NO restart
```

- Readiness controls **traffic**, not restarts (that's what a liveness probe is for).
- The Service only ever load-balances across **ready** endpoints.
- `kubectl get endpoints` is the fastest way to confirm which pods are actually serving.
- This is the foundation of safe rollouts: new pods only receive traffic once they report
  ready.

---

## Cleanup

```bash
kubectl delete ns canary-demo
```
This removes both pods, the Service, and the namespace in one go.
