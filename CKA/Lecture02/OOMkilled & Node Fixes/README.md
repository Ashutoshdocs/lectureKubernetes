# Kubernetes Resilience Demo 🎡

A tiny, colourful web app for demonstrating two classic Kubernetes self-healing
behaviours in front of a live audience:

- **Demo 1 — OOMKilled:** a container exceeds its memory limit, gets killed, and
  is automatically restarted.
- **Demo 2 — Pod Rescheduling:** a Pod is removed from a node, and the Deployment
  creates a replacement Pod that lands on another node.

The app is exposed through both a **ClusterIP** Service (internal) and a
**LoadBalancer** Service (browser-facing). Every time you hit it in the browser
it shows, on a colourful glassmorphism page:

- the **container name**
- the **node (hostname)** the request landed on
- the **pod name**, pod IP, and namespace
- the **time the container started** (plus a live uptime counter)

Each pod gets its own deterministic gradient, so when the LoadBalancer sends you
to a different pod/node **the page visibly changes colour** — great for showing
load balancing and rescheduling at a glance.

---

## 📁 Repository layout

```
k8s-resilience-demo/
├── README.md
├── app/
│   ├── app.py            # Flask app: colourful page + /leak (OOM) + /api + /healthz
│   ├── requirements.txt
│   └── Dockerfile
└── k8s/
    ├── deployment.yaml   # 3 replicas, memory limit 64Mi, Downward API env, probes
    ├── service.yaml      # ClusterIP  (internal)
    └── service-lb.yaml   # LoadBalancer (browser)
```

---

## ✅ Prerequisites

- A Kubernetes cluster (kind, minikube, k3d, Docker Desktop, GKE/EKS/AKS…)
- `kubectl` configured to talk to it
- A container registry you can push to **or** a local cluster where you can load
  the image directly (kind / minikube)

---

## 🛠️ Build & push the image

Replace `your-registry/k8s-resilience-demo:1.0` in `k8s/deployment.yaml` with
your own image reference.

```bash
cd app
docker build -t your-registry/k8s-resilience-demo:1.0 .
docker push  your-registry/k8s-resilience-demo:1.0
```

**Local clusters (no registry needed):**

```bash
# kind
kind load docker-image your-registry/k8s-resilience-demo:1.0

# minikube
minikube image load your-registry/k8s-resilience-demo:1.0
```

> The Deployment uses `imagePullPolicy: IfNotPresent`, so locally loaded images
> are picked up without a pull.

---

## 🚀 Deploy

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/service-lb.yaml

# Watch the pods spread across nodes
kubectl get pods -o wide -w
```

---

## 🌐 Open it in the browser

Get the LoadBalancer address:

```bash
kubectl get svc resilience-demo-lb
```

- **Cloud cluster:** use the `EXTERNAL-IP` shown, e.g. `http://<EXTERNAL-IP>/`
- **minikube:**
  ```bash
  minikube service resilience-demo-lb
  ```
- **kind / no external LB:** port-forward instead:
  ```bash
  kubectl port-forward svc/resilience-demo-lb 8080:80
  # then open http://localhost:8080/
  ```

Refresh a few times — the **node name, pod name, and page colour** change as the
Service balances you across pods on different nodes. 🎨

Extra endpoints: `GET /api` (JSON), `GET /healthz` (probe), `GET /leak?mb=40`
(memory leak for Demo 1).

---

## 💥 Demo 1 — OOMKilled

**Goal:** show a container exceeding its memory limit, being killed, and
restarting automatically.

The container has `limits.memory: 64Mi`. The app's **“💥 Leak 40 MB”** button (or
`GET /leak?mb=40`) allocates memory that is never freed, so **two clicks push it
past the limit** and the kubelet OOM-kills the container.

**Run it:**

1. Watch the pods in one terminal:
   ```bash
   kubectl get pods -w
   ```
2. In the browser, click **“💥 Leak 40 MB (OOM)”** twice (or hit the endpoint):
   ```bash
   curl "http://<address>/leak?mb=40"
   curl "http://<address>/leak?mb=40"
   ```
3. Watch the pod's `RESTARTS` count tick up. Confirm the reason:
   ```bash
   kubectl describe pod <pod-name> | grep -A3 "Last State"
   # Reason: OOMKilled, Exit Code: 137
   ```

**What to point out:**
- `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`.
- Kubernetes restarts the **same** pod on the **same** node (container restart,
  not rescheduling). The **“Started at”** time resets while the **pod name stays
  the same**.
- With `restartPolicy: Always` (the Deployment default) this recovery is automatic.

> Tip: repeated crashes lead to `CrashLoopBackOff` — a good talking point about
> back-off timing.

---

## 🔀 Demo 2 — Pod Rescheduling

**Goal:** show that when a Pod is removed from a node, the Deployment creates a
replacement that can be scheduled onto another node.

**Option A — delete a pod (simplest):**

```bash
kubectl get pods -o wide          # note names + NODE column
kubectl delete pod <pod-name>
kubectl get pods -o wide -w       # a brand-new pod appears, possibly on another node
```

The Deployment's ReplicaSet notices it is one pod short and creates a
replacement. In the browser, the **pod name and “Started at” change**, and the
**node** (and page colour) may change too.

**Option B — drain a node (closer to a real maintenance event):**

```bash
kubectl get nodes
kubectl cordon <node-name>                       # stop new pods landing here
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

kubectl get pods -o wide -w                       # evicted pods reschedule elsewhere

# Put the node back when you're done
kubectl uncordon <node-name>
```

**What to point out:**
- The **desired replica count is maintained** even as individual pods come and go.
- Replacement pods can land on a **different node** — the browser proves it by
  showing a new node hostname and a new colour.
- `topologySpreadConstraints` in the Deployment encourages an even spread across
  nodes.

---

## 🔎 Handy commands

```bash
kubectl get pods -o wide                     # pods + which node each is on
kubectl get deploy,rs,svc                    # the full picture
kubectl logs -f <pod-name>                   # app logs
kubectl describe pod <pod-name>              # events, restarts, OOM reason
kubectl get events --sort-by=.lastTimestamp  # cluster events timeline
```

---

## 🧹 Cleanup

```bash
kubectl delete -f k8s/service-lb.yaml
kubectl delete -f k8s/service.yaml
kubectl delete -f k8s/deployment.yaml
```

---

## ⚙️ How it works

- **Node & pod identity** are injected into the container with the Kubernetes
  **Downward API** (`spec.nodeName`, `metadata.name`, `status.podIP`,
  `metadata.namespace`). The container name isn't exposed by the Downward API, so
  it's set as a plain env var.
- **Start time** is captured once when the process starts, so a restart (Demo 1)
  or a fresh pod (Demo 2) is obvious from the timestamp and uptime.
- **The colour** is a hash of the pod name → a stable gradient, so each pod looks
  distinct and switches are visible instantly.
- **The OOM** is caused on demand by `/leak`, which appends 1 MB blocks to a
  module-level list that is never garbage-collected.

Tune the demo by editing `resources.limits.memory` in `k8s/deployment.yaml` and
the `mb` value on the leak button/endpoint.
