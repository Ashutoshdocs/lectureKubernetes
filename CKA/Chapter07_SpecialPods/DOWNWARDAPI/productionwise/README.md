# Kubernetes ConfigMap App + Log-Search Demo — Customer Support Portal

A small but complete demo that ties together several core Kubernetes ideas: shipping app
**code through a ConfigMap**, running **3 replicas** behind a **NodePort Service**, tagging
each request with **which pod/node handled it** (the Downward API), and a **support script**
that searches the logs of *all* pods at once to find a customer's request.

```
Browser ──▶ NodePort Service ──load-balances──▶ 3 webapp pods (Flask)
                                                   │ each logs USER=, PHONE=, POD=, NODE=
                                                   ▼
                              support.sh ── kubectl logs -l app=webapp ──▶ finds a customer
```

---

## What this demo teaches

### 1. Ship code with a ConfigMap (no image rebuild)
The Flask app (`app.py`) lives entirely inside a **ConfigMap** (`webapp-code`) and is mounted
into the container at `/app`. The container is a plain `python:3.12-slim` that just
`pip install flask` and runs the mounted file. **You can change the app by editing the
ConfigMap** — no Docker build, no registry push. (Great for demos; see the prod note below.)

### 2. Deployments and replicas
The Deployment runs **3 replicas** of the app, all selected by `app: webapp`. This is what
lets the next two ideas — load balancing and multi-pod log search — actually mean something.

### 3. The Downward API — a pod knows its own identity
Each pod injects its own name and node into environment variables:
```yaml
env:
- name: POD_NAME
  valueFrom: { fieldRef: { fieldPath: metadata.name } }
- name: NODE_NAME
  valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
```
The app stamps `POD=` and `NODE=` into every log line, so you can see **which replica served
each request** — a clean way to observe load balancing.

### 4. Service load balancing (NodePort)
The `webapp-service` (NodePort) fronts all 3 pods and spreads requests across them. Submit
the form a few times and you'll see different `POD=` values in the logs.

### 5. Aggregated logs + a real support workflow
`support.sh` asks for a customer username, then runs `kubectl logs -l app=webapp` — which
pulls logs from **every pod matching the label** — and uses `awk` to print the matching
request block (case-insensitive). This is a realistic "find this customer's ticket across the
whole fleet" tool.

---

## Files in this repo

| File            | What it is                                                                  |
|-----------------|----------------------------------------------------------------------------|
| `configmap.yml` | `webapp-code` ConfigMap containing the full Flask `app.py` (the portal UI). |
| `deployment.yml`| Deployment of **3** `webapp` replicas; mounts the ConfigMap, injects POD/NODE via Downward API. |
| `service.yml`   | `NodePort` Service `webapp-service` → container port 5000 (published on port 80). |
| `support.sh`    | Interactive log-search tool: enter a username, see their request across all pods. |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.
- Cluster egress to PyPI (the container runs `pip install flask` at startup).

---

## Steps

### 1. Apply the ConfigMap FIRST
The Deployment mounts it, so it must exist before the pods start.
```bash
kubectl apply -f configmap.yml
```

### 2. Deploy the app and the Service
```bash
kubectl apply -f deployment.yml
kubectl apply -f service.yml
```

### 3. Wait for all 3 replicas to be ready
```bash
kubectl get pods -l app=webapp -w
```
Expected — three pods, each `1/1 Running` (give them a moment for `pip install`):
```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-xxxxxxxxx-aaaaa    1/1     Running   0          ...
webapp-xxxxxxxxx-bbbbb    1/1     Running   0          ...
webapp-xxxxxxxxx-ccccc    1/1     Running   0          ...
```
(Press `Ctrl+C` to stop watching.)

### 4. Find the NodePort and open the portal
```bash
kubectl get svc webapp-service
```
```bash
curl http://<NodeIP>:<nodePort>/      # or open in a browser
```
> **minikube:** `minikube service webapp-service --url` gives a reachable URL.

You'll see the "Customer Portal" page. Fill in name / phone / query and submit — you get a
"Request received" confirmation.

### 5. Submit a few requests, then watch them land on different pods
Submit the form several times (different names), then look at the aggregated logs:
```bash
kubectl logs -l app=webapp --tail=50
```
Each submission prints a block like:
```
TIME=2026-09-18 22:50:01
USER=Jordan Rivera
PHONE=+1 555 012 3456
QUERY=Cannot log in
RESPONSE_TIME=12s
POD=webapp-xxxxxxxxx-bbbbb      ← which replica handled it
NODE=<node name>
```
Different requests show different `POD=` values — that's the Service load-balancing across
your 3 replicas.

---

## Use the support tool

### 6. Run the search script
```bash
chmod +x support.sh
./support.sh
```
It prompts:
```
Enter Customer Username: jordan
```
It then runs `kubectl logs -l app=webapp`, searches **all pods'** logs case-insensitively for
`USER=jordan`, and prints that customer's request block (the matching line plus surrounding
context). This is the "look up a customer across the whole deployment" workflow.

> The script matches on the lowercased username, so `Jordan`, `jordan`, and `JORDAN` all find
> the same record.

---

## Change the app WITHOUT rebuilding an image

This is the payoff of putting code in a ConfigMap:

### 7. Edit the ConfigMap and roll the pods
```bash
kubectl edit configmap webapp-code       # change some text in app.py
kubectl rollout restart deployment webapp # restart pods so they re-read the mounted code
kubectl get pods -l app=webapp -w
```
After the restart, reload the portal and your change is live — no `docker build`, no push.

---

## Key takeaways

- A **ConfigMap** can carry an app's *code/config* and be mounted as files — edit it and
  restart to ship changes without rebuilding an image.
- A **Deployment** with multiple **replicas** + a **Service** gives you load balancing across
  pods.
- The **Downward API** (`fieldRef`) lets each pod log its own `POD_NAME`/`NODE_NAME`, so you
  can see which replica served a request.
- `kubectl logs -l <label>` reads logs from **all matching pods** — the basis of the
  `support.sh` cross-fleet search.

> **Prod notes:** shipping code via ConfigMap and running `pip install` at startup is great
> for a demo but not for production — there you'd **bake the app and its dependencies into a
> container image**. ConfigMaps are best kept for *configuration*, and anything sensitive
> (credentials, tokens) belongs in a **Secret**. For real log search across pods, a log
> aggregator (Loki, ELK, Cloud logging) replaces `kubectl logs`.

---

## Cleanup

```bash
kubectl delete -f service.yml -f deployment.yml -f configmap.yml
```
