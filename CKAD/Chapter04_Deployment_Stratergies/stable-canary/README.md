# Kubernetes Canary Deployment — Hands-On Demo

A demo of the **canary deployment** pattern: send a **small slice** of live traffic to a new
version while **most** users stay on the stable one. If the canary looks healthy, you grow it;
if not, you scale it to zero — instantly. Here the traffic split is controlled by the
**ratio of replicas** sitting behind a single Service.

```
                 api-svc  (selector: app=web  → matches BOTH versions)
                              │  load-balances across ALL matching pods
        ┌──────────────────────────────────────────────┐
        ▼                                                ▼
   stable Deployment (8 pods)                       canary Deployment (2 pods)
   "I AM STABLE VERSION"                            "I AM CANARY VERSION"
        └──────────  ~80% of traffic  ──────┘  └──── ~20% of traffic ────┘
```

---

## What this demo teaches

### The canary pattern
Instead of switching everyone at once, you release the new version to a **fraction** of users
first — the "canary." You watch it under real traffic, then **gradually shift more** traffic
to it as confidence grows, or **roll it back** if it misbehaves.

### How the traffic split works here (replica ratio)
This is the clever, dependency-free part:
- **One Service** (`api-svc`) selects **`app: web`** — a label that **both** the stable and
  canary Deployments carry.
- So the Service load-balances across **all** stable **and** canary pods together.
- The **share of traffic each version gets ≈ its share of the total pods.**

| stable / canary replicas | Total pods | Canary traffic (approx) |
|--------------------------|-----------|--------------------------|
| 8 / 2                    | 10        | ~20%                     |
| 5 / 5                    | 10        | ~50%                     |
| 0 / 10                   | 10        | 100% (fully promoted)    |
| 10 / 0                   | 10        | 0% (rolled back)         |

To change the split, you just **scale the Deployments** — no config, no router rules.

> This is a simple, real way to do canaries with plain Kubernetes. It's **coarse** (the split
> is limited by pod counts) and **random per-request**. Fine-grained, header-based canaries
> use a service mesh (Istio, Linkerd) or an ingress controller — noted at the end.

### Stable vs canary content
Each version serves a different page from its own ConfigMap (light-blue **"I AM STABLE
VERSION"** vs khaki **"I AM CANARY VERSION"**), so repeated requests visibly land on one or the
other in roughly the replica ratio.

---

## Files in this repo

| File                              | What it is                                                       |
|-----------------------------------|-----------------------------------------------------------------|
| `stable.yml`                      | `stable` Deployment (labels `app: web, version: stable`).       |
| `configmap-stable.yml`            | `stable-html` — the blue "STABLE" page.                         |
| `canary.yml`                      | `canary` Deployment (labels `app: web, version: canary`).       |
| `configmap-canary.yml`            | `canary-html` — the khaki "CANARY" page.                        |
| `service_for_canary_stable.yml`   | `api-svc` NodePort selecting **`app: web`** (both versions).    |
| `commands.txt`                    | The apply + scale (traffic-shift) commands.                     |

> **Key detail:** the Service selector is **only `app: web`** — it deliberately does *not*
> pin `version`, which is exactly why one Service fronts both versions at once.

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Steps

### 1. Deploy the stable version and the Service
```bash
kubectl apply -f configmap-stable.yml
kubectl apply -f stable.yml
kubectl apply -f service_for_canary_stable.yml
```

### 2. Deploy the canary version
```bash
kubectl apply -f configmap-canary.yml
kubectl apply -f canary.yml
```

### 3. Set the initial split to ~80/20
```bash
kubectl scale deployment stable --replicas=8
kubectl scale deployment canary --replicas=2
kubectl get deploy
```
Expected — `stable 8/8`, `canary 2/2` (10 pods total, all behind `api-svc`).

### 4. Send traffic and watch the split
The Service is a NodePort on `30080`. Hit it repeatedly and count the versions:
```bash
for i in $(seq 1 20); do
  curl -s http://<NODE-IP>:30080 | grep -o 'STABLE\|CANARY'
done | sort | uniq -c
```
Expected — roughly **16 STABLE / 4 CANARY** (≈80/20, with random variation):
```
     16 STABLE
      4 CANARY
```
> **minikube:** get the URL with `minikube service api-svc --url` and use that host:port.

---

### 5. Increase the canary to ~50/50
Once the canary looks healthy, give it more traffic:
```bash
kubectl scale deployment stable --replicas=5
kubectl scale deployment canary --replicas=5
```
Re-run the curl loop — now it's roughly half and half.

### 6. Fully promote the canary (100%)
When you're confident, shift everything to the new version:
```bash
kubectl scale deployment stable --replicas=0
kubectl scale deployment canary --replicas=10
```
Every request now returns **CANARY**. (In a real workflow you'd then update `stable` to the
new image and flip back, making the new version the stable baseline.)

### 7. Roll back instantly (if the canary misbehaves)
At any point, send all traffic back to stable:
```bash
kubectl scale deployment stable --replicas=10
kubectl scale deployment canary --replicas=0
```
Because the stable pods were running the whole time, rollback is immediate.

---

## What to watch

```bash
# how many pods of each version are in rotation:
kubectl get pods -l app=web -L version

# the Service's endpoints = every pod receiving traffic (both versions):
kubectl get endpoints api-svc -o wide

# live deployment replica counts:
kubectl get deploy stable canary -w
```

---

## Key takeaways

- A **canary** releases a new version to a **small slice** of traffic first, then grows it as
  confidence builds — or scales it to zero to roll back.
- With plain Kubernetes, the split is done by the **replica ratio** behind a Service whose
  selector matches **both** versions (`app: web`), so ~traffic% ≈ pod%.
- **Shift traffic by scaling**: `kubectl scale` up canary / down stable.
- **Promote** = scale stable to 0; **rollback** = scale canary to 0 — both instant.
- This is coarse and random-per-request; for **precise or header-based** routing (e.g. exactly
  5%, or only internal users), use a **service mesh** (Istio/Linkerd) or an ingress controller.

---

## Cleanup

```bash
kubectl delete -f canary.yml -f configmap-canary.yml \
               -f stable.yml -f configmap-stable.yml \
               -f service_for_canary_stable.yml
```
