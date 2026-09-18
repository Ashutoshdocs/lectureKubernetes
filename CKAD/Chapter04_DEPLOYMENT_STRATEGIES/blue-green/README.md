# Kubernetes Blue-Green Deployment — Hands-On Demo

A demo of the **blue-green deployment** pattern: run **two versions side by side** (blue =
current, green = new) and switch **all traffic** from one to the other **instantly** by
changing a single label on the Service. If the new version misbehaves, you switch back just
as fast.

```
                    web-svc (selector: version=blue)
                              │
        ┌─────────────────────┴─────────────────────┐
        ▼                                            ▼
   blue Deployment (v1)                        green Deployment (v2)
   2 pods, "BLUE" page                         2 pods, "GREEN" page
   ← receiving traffic                         ← running, idle, ready

   Flip the Service selector to version=green → traffic moves instantly
```

---

## What this demo teaches

### The blue-green pattern
- **Blue** is the version currently serving users. **Green** is the new version.
- You deploy green **alongside** blue and let it fully come up — but **no traffic** goes to it
  yet.
- A **Service** routes traffic using a label **selector**. It points at `version: blue`.
- To release, you **change the selector to `version: green`**. Because both versions are
  already running, the cutover is **instant** — no waiting for pods to start.
- **Rollback is just as instant**: point the selector back to `version: blue`.

### Why it's useful
- **Zero-downtime releases** — green is already warm when you switch.
- **Instant rollback** — the old version is still running, untouched.
- **Test before switching** — you can hit green directly (see below) before sending real users
  to it.

### How the switch actually works
The magic is the Service **selector matching pod labels**:
- Both Deployments share `app: web` but differ on `version: blue` / `version: green`.
- The Service selects `app: web, version: blue`, so only blue's pods are endpoints.
- `kubectl patch` rewrites the selector to `version: green`, and the Service's endpoints
  immediately become green's pods.

> The two pages (light-blue "BLUE" vs light-green "GREEN") are served from ConfigMaps mounted
> as `index.html`, so you can **see** which version answered in your browser.

---

## Files in this repo

| File               | What it is                                                                 |
|--------------------|---------------------------------------------------------------------------|
| `blue.yml`         | `blue` Deployment (2 replicas) + `blue-html` ConfigMap (the blue page).    |
| `green.yml`        | `green` Deployment (2 replicas) + `green-html` ConfigMap (the green page). |
| `svc_blue-green.yml`| `web-svc` NodePort Service — starts pointing at `version: blue`.          |
| `blue-green_steps.txt`| The core apply + patch commands.                                        |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Steps

### 1. Deploy BLUE and the Service
```bash
kubectl apply -f blue.yml
kubectl apply -f svc_blue-green.yml     # selector = version: blue
```

### 2. Confirm blue is up and serving
```bash
kubectl get pods -l app=web -w          # wait for 2 blue pods Running
kubectl get svc web-svc                 # note the NodePort
```
Open it — you should see the **light-blue "You hit BLUE deployment!"** page:
```bash
curl http://<NodeIP>:<nodePort>
# minikube: minikube service web-svc --url
```

### 3. Deploy GREEN alongside blue (no traffic yet)
```bash
kubectl apply -f green.yml
kubectl get pods -l app=web
```
Expected — **4 pods** now running (2 blue + 2 green), but the Service still points at blue, so
users still see blue:
```
NAME                     READY   STATUS    ...   version
blue-xxxxxxxxx-aaaaa     1/1     Running         blue
blue-xxxxxxxxx-bbbbb     1/1     Running         blue
green-xxxxxxxxx-ccccc    1/1     Running         green
green-xxxxxxxxx-ddddd    1/1     Running         green
```

### 4. (Recommended) Test green BEFORE switching
Verify green works while real traffic still goes to blue:
```bash
# port-forward straight to a green pod
kubectl port-forward deploy/green 8080:80
# in another terminal:
curl http://localhost:8080      # → "You hit GREEN deployment!"
```
This is the safety step blue-green gives you — validate the new version privately first.

### 5. Switch traffic to GREEN (the cutover)
```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
```

### 6. Confirm the switch
```bash
kubectl get endpoints web-svc          # endpoints are now green pod IPs
curl http://<NodeIP>:<nodePort>        # → "You hit GREEN deployment!"
```
The change is **instant** — green was already running, so there's no cold start. ✅

### 7. Roll back to BLUE (just as instant)
If green has a problem, flip the selector straight back:
```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
curl http://<NodeIP>:<nodePort>        # → back to BLUE
```

### 8. Decommission the old version (once green is proven)
When you're confident in green, remove blue to free resources:
```bash
kubectl delete -f blue.yml
```

---

## What to watch to really "see" it

```bash
# which pods the Service currently sends traffic to:
kubectl get endpoints web-svc -o wide

# the Service's live selector (blue or green):
kubectl get svc web-svc -o jsonpath='{.spec.selector}{"\n"}'

# all versions running right now:
kubectl get pods -l app=web -L version
```
Before the patch, the endpoints are blue pod IPs; after the patch, they're green — nothing
about the pods changed, only which ones the Service selects.

---

## Blue-green vs rolling update (quick contrast)

| | Blue-Green | Rolling update (default Deployment) |
|--|-----------|-------------------------------------|
| Both versions live at once | Yes (full copies) | Briefly, mixed |
| Cutover | Instant, all-at-once | Gradual, pod by pod |
| Rollback speed | Instant (flip selector) | Re-roll, slower |
| Resource cost | Higher (2× during release) | Lower |
| Test new version privately | Easy (green is separate) | Harder |

---

## Key takeaways

- Blue-green runs **two complete versions** and switches traffic by **changing the Service's
  label selector** — the cutover and the rollback are both **instant**.
- Both Deployments share `app: web` but differ by `version`; the Service selects one version
  at a time.
- You can **validate green privately** (port-forward) before sending users to it.
- Trade-off: you pay for **2× the pods** during the release window.

---

## Cleanup

```bash
kubectl delete -f green.yml -f blue.yml -f svc_blue-green.yml
```
