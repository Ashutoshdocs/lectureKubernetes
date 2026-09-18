# Colour Web — Kubernetes load-balancing demo

A tiny demo that answers a very common question:

> "I have a LoadBalancer service and several pods, but the browser keeps hitting
> the **same pod** every time. Why? And how do I get traffic spread across all
> of them?"

Each pod serves a page in a **colour derived from its own name**, so different
pods look unmistakably different. Refresh the browser and you'll usually see the
*same* colour — that's the behaviour we're going to explain and fix.

---

## What's in here

| File | Purpose |
|------|---------|
| `app.py` | The web server (Python standard library only — no build, no registry). Reads its identity from the Downward API and renders it. |
| `configmap.yaml` | Ships `app.py` into the cluster as a ConfigMap, so **no container image build is required**. |
| `deployment.yaml` | 4 replicas of `python:3.12-alpine` running the app, with `POD_NAME` / `NODE_NAME` / `POD_IP` injected via the Downward API. |
| `service.yaml` | A `type: LoadBalancer` service in front of the pods. |

---

## 1. Deploy

```bash
kubectl apply -f .
kubectl rollout status deploy/color-web
kubectl get pods -l app=color-web -o wide
```

You should see 4 pods, ideally on different nodes.

## 2. Reach it

How you get an address depends on your cluster:

```bash
# Cloud (EKS / GKE / AKS) or Docker Desktop — wait for EXTERNAL-IP:
kubectl get svc color-web -w

# minikube:
minikube service color-web --url        # prints a URL to open
# (or run `minikube tunnel` in another terminal, then use EXTERNAL-IP)

# kind / bare clusters with no cloud LB (EXTERNAL-IP stays <pending>):
#   install MetalLB, OR just port-forward (see the caveat in step 4).
```

Open the address in a browser. You'll get a glowing, coloured pod page.

---

## 3. The problem: always the same pod

Refresh the page several times in the browser. The colour (and the pod name)
almost always **stays the same**, and that one pod's request counter keeps
climbing. It looks broken. It usually isn't. Here's why.

### Why it happens

**#1 cause — HTTP keep-alive + connection-level load balancing.**
A Kubernetes `Service` is an **L4 (TCP) load balancer**. `kube-proxy` picks a
backend pod **once, when the TCP connection is opened**, and then every request
on that connection goes to the same pod (the choice is tracked by conntrack).

Browsers keep the TCP connection open and reuse it (HTTP keep-alive), so all
your refreshes travel down **one connection → one pod**. This is working
exactly as designed; it just isn't what people expect.

Other common causes, worth checking:

- **`sessionAffinity: ClientIP` on the Service.** This deliberately pins every
  request from one client IP to one pod (default 3-hour timeout). If it's set,
  you *will* always hit the same pod. This demo sets it to `None`.
- **`externalTrafficPolicy: Local`.** Routes traffic only to pods on the node
  that received it. If your external LB keeps sending you to the same node, you
  keep hitting that node's pods. The default, `Cluster`, spreads across all pods.
- **The external cloud LB hashes on source IP.** Some cloud LBs send a given
  client to a fixed node/target. Combined with keep-alive, that's very sticky.
- **Only one pod is actually `Ready`.** Then there's nothing to spread to.
  Check with `kubectl get endpointslices -l kubernetes.io/service-name=color-web`.
- **You're using `kubectl port-forward`.** Port-forward always tunnels to a
  **single** pod — great for viewing the app, useless for showing distribution.

---

## 4. Prove that distribution actually works

The trick is to make **new TCP connections** instead of reusing one. `curl`
opens a fresh connection per invocation, so a loop spreads across pods. Each
response carries an `X-Pod-Name` header we can read:

```bash
IP=$(kubectl get svc color-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# no external IP? use hostname, the minikube URL, or port-forward's address.

for i in $(seq 1 20); do
  curl -s -D - -o /dev/null "http://$IP/" | grep -i '^X-Pod-Name'
done | sort | uniq -c
```

You'll see the 20 requests spread across all 4 pods — proof the Service load
balances fine. Now contrast that with reusing **one** connection, which sticks
to a single pod (this mimics the browser):

```bash
# All requests share one connection -> one pod:
curl -s "http://$IP/" "http://$IP/" "http://$IP/" "http://$IP/" \
  -D - -o /dev/null | grep -i '^X-Pod-Name'
```

> Tip: forcing `Connection: close` (`curl -H "Connection: close"`) on each
> request also spreads traffic, because every request becomes its own
> connection.

### The browser will still stick — that's expected

Even after you've proven distribution works via curl, the browser keeps hitting
one pod because it holds the connection open. That's normal L4 behaviour. If you
need **per-request** spreading in the browser, read the next section.

---

## 5. How to ensure traffic is distributed

Pick the level that matches what you actually need:

1. **Don't accidentally pin traffic.** Keep `sessionAffinity: None` (unless you
   *want* stickiness) and prefer the default `externalTrafficPolicy: Cluster`
   for even spread across all pods. Verify the pods are all `Ready` and appear
   as endpoints.

2. **Accept L4 behaviour for long-lived clients.** For a plain Service, "one
   connection → one pod" is correct. Many short-lived clients (typical web
   traffic, API calls without aggressive pooling) spread naturally.

3. **Add an L7 proxy for true per-request balancing.** If you want each HTTP
   request balanced regardless of connection reuse, put a layer-7 hop in front:
   - an **Ingress controller** (NGINX, Traefik, HAProxy) or a **Gateway API**
     implementation, or
   - a **service mesh** (Istio, Linkerd) — these balance per request and can do
     round-robin / least-request across pods even over a single client
     connection.

4. **Tune keep-alive at the proxy** if you use one — e.g. NGINX
   `keepalive_requests` / `keepalive_timeout` — to periodically rebalance
   long-lived connections.

**Short version:** a `Service` load-balances **connections**, not requests. For
request-level distribution in the browser, front it with an Ingress or a mesh.

---

## 6. Quick troubleshooting checklist

| Symptom | Check | Fix |
|--------|-------|-----|
| Same pod on every browser refresh | HTTP keep-alive (expected at L4) | Test with a `curl` loop; add Ingress/mesh for per-request spread |
| Same pod even with a curl loop | `kubectl get svc color-web -o yaml \| grep sessionAffinity` | Set `sessionAffinity: None` |
| Only pods on one node get traffic | `externalTrafficPolicy` | Use `Cluster` (default) |
| `EXTERNAL-IP` stuck `<pending>` | No cloud LB (kind/bare metal) | Install MetalLB, or use `minikube tunnel`, or port-forward |
| Traffic never spreads via port-forward | port-forward targets one pod | Use the real Service IP, not port-forward, for distribution tests |
| Fewer pods answering than expected | `kubectl get endpointslices -l kubernetes.io/service-name=color-web` | Fix failing readiness probes so all pods are `Ready` |

Handy commands:

```bash
kubectl get pods -l app=color-web -o wide
kubectl get svc color-web
kubectl get endpointslices -l kubernetes.io/service-name=color-web
kubectl logs -l app=color-web --prefix --tail=20
```

---

## 7. Clean up

```bash
kubectl delete -f .
```

---

### How the app knows its own name

The pod's identity isn't hard-coded — it's injected at runtime through the
**Downward API** in `deployment.yaml`:

```yaml
env:
  - name: POD_NAME
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
  - name: NODE_NAME
    valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
  - name: POD_IP
    valueFrom: { fieldRef: { fieldPath: status.podIP } }
```

`app.py` reads those env vars and turns `POD_NAME` into a hue, so the colour is
stable per pod and different between pods.
