# PodDisplay CRD console — install and run

A custom resource called `PodDisplay` is reconciled into a Deployment. The
operator watches every deployment, replicaset and pod in the cluster and streams
them to a browser console with four pages, where you can change the replica
count, update the image, and drive rollouts.

```
PodDisplay CR ──▶ operator ──▶ Deployment ──▶ ReplicaSet ──▶ Pods
                     │
                     └── watches all four kinds ──▶ SSE ──▶ browser :8080
                     ▲
                     └── the console writes back: scale / set image / rollout
```

## The four pages

| Page | What it answers |
|---|---|
| **Overview** | How many poddisplays, deployments, replicasets and pods; ready vs desired replicas across the cluster; which rollouts are in flight; a live event log |
| **Deployments** | Per deployment: replica count as a strip of pips (ready / starting / retiring), ready-updated-available counts, revision, image, source. Controls: **− n +  Apply** to change replicas, an image box with **Update image**, and **Restart / Pause / Undo / Delete** |
| **ReplicaSets** | Replicasets grouped under their deployment, one row per revision, marked current / active / history — this is the rollout history `kubectl rollout undo` walks back through |
| **Pods** | Every pod with phase, ready containers, restarts, node, IP and owning replicaset |

Scaling or changing the image on a deployment that a `PodDisplay` owns writes to
the **custom resource**, not the deployment — so you watch the operator do the
work. Deployments created outside the CRD are patched directly.

## 1. Prerequisites

| Tool | Version | Check |
|---|---|---|
| Python | 3.10+ | `python3 --version` |
| kubectl | 1.25+ | `kubectl version --client` |
| A cluster | kind, minikube, k3d, Docker Desktop… | `kubectl cluster-info` |

Ubuntu/Debian:

```bash
sudo apt update && sudo apt install -y python3 python3-venv python3-pip curl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
```

macOS: `brew install python kubectl kind`

## 2. Start a cluster (skip if you have one)

```bash
kind create cluster --name crd-demo     # or: minikube start
```

## 3. Scaffold the project

```bash
bash create-crd-demo.sh          # creates ./crd-pod-demo
cd crd-pod-demo
```

Upgrading from the earlier pod-only version? Remove the old objects first, since
the CRD schema and the managed object both changed:

```bash
kubectl delete poddisplays --all -n crd-demo --ignore-not-found
kubectl delete crd poddisplays.demo.example.com --ignore-not-found
```

## 4. Install dependencies and run

```bash
./scripts/run-local.sh
```

That creates a virtualenv, installs `kopf`, `kubernetes`, `fastapi` and
`uvicorn`, applies the CRD, creates the `crd-demo` namespace, and starts the
operator and web server in one process.

Manual equivalent:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r operator/requirements.txt
kubectl apply -f manifests/crd.yaml
kubectl create namespace crd-demo
cd operator && python main.py
```

## 5. Open the console

<http://localhost:8080> — the dot turns cyan when the watch stream connects.

## 6. Create something to look at

```bash
kubectl apply -f manifests/sample-poddisplay.yaml   # 3 busybox + 2 nginx replicas
./scripts/new-pod.sh my-app 4                       # name, replica count
./scripts/burst.sh 4                                # several, spaced out
```

Or use the **Create PodDisplay** form at the top of the Deployments page.

## 7. Drive it from the UI

On the **Deployments** page:

- **Replica count** — press `−` / `+` or type a number, then **Apply**. The pip
  strip and the Pods page react immediately; the ReplicaSets page shows the same
  replicaset changing its desired count (no new revision — scaling is not a rollout).
- **Update image** — type e.g. `busybox:1.37` and press **Update image**. The
  badge moves through Rolling out → Retiring old pods → Complete, a new
  replicaset appears on the ReplicaSets page with the next revision, and the old
  one drops to zero but stays as history.
- **Restart** — replaces every pod without changing the spec (`kubectl rollout restart`).
- **Pause / Resume** — freezes a rollout part-finished, so you can see one
  replicaset at the new image and one at the old, both non-zero.
- **Undo** — copies the previous revision's pod template back, like `kubectl rollout undo`.
- **Delete** — deletes the `PodDisplay`; the deployment, replicasets and pods
  follow through owner references.

## 8. The same things from kubectl

```bash
kubectl get poddisplays -n crd-demo
kubectl get deploy,rs,pods -n crd-demo

./scripts/scale.sh hello-world 5
./scripts/set-image.sh hello-world busybox:1.37
./scripts/rollout.sh history hello-world
./scripts/rollout.sh undo hello-world
./scripts/rollout.sh restart hello-world

kubectl scale poddisplay hello-world -n crd-demo --replicas=6   # the scale subresource
```

Every one of these shows up in the console within a second — the UI is a view of
the cluster, not of its own actions.

## 9. Clean up

```bash
./scripts/cleanup.sh
kind delete cluster --name crd-demo
```

---

## Optional: run the operator inside the cluster

```bash
docker build -t poddisplay-operator:dev .
kind load docker-image poddisplay-operator:dev --name crd-demo
kubectl apply -f manifests/rbac.yaml
kubectl apply -f manifests/operator-deployment.yaml
kubectl port-forward -n crd-demo svc/poddisplay-ui 8080:8080
```

## Files

```
crd-pod-demo/
├── manifests/
│   ├── crd.yaml                    PodDisplay CRD: image, replicas, message, colour
│   ├── sample-poddisplay.yaml      two example custom resources
│   ├── rbac.yaml                   ServiceAccount + ClusterRole (in-cluster only)
│   └── operator-deployment.yaml    Deployment + Service (in-cluster only)
├── operator/
│   ├── controller.py               reconcile CR -> Deployment; watch all four kinds
│   ├── k8s.py                      API clients + the summarizers the UI renders
│   ├── actions.py                  scale, set-image, restart, pause, undo, create, delete
│   ├── broker.py                   fan-out from the watches to every browser tab
│   ├── web.py                      FastAPI: /api/state, /api/events (SSE), actions
│   ├── main.py                     runs kopf + uvicorn in one event loop
│   ├── requirements.txt
│   └── static/                     index.html · styles.css · app.js
├── scripts/
│   ├── run-local.sh                install deps, apply CRD, start everything
│   ├── new-pod.sh                  create a PodDisplay
│   ├── scale.sh                    change spec.replicas
│   ├── set-image.sh                roll out a new image
│   ├── rollout.sh                  restart / status / history / undo / pause / resume
│   ├── burst.sh                    create several
│   └── cleanup.sh                  remove everything
├── Dockerfile
└── STEPS.md
```

## Troubleshooting

**Nothing appears** — check `kubectl auth can-i watch deployments --all-namespaces`.
Locally the operator uses your kubeconfig; in-cluster it needs `manifests/rbac.yaml`.

**A rollout never finishes** — the new image probably can't be pulled. The Pods
page shows `ImagePullBackOff`; press **Undo** to go back to the last good revision.

**`nginx` pods restart-loop** — only busybox/alpine-style images get the print
loop; other images keep their own entrypoint, so use images that stay running.

**Port 8080 taken** — `PORT=9090 ./scripts/run-local.sh`.

**The CRD rejects `replicas`** — an old copy of the CRD is still registered:
`kubectl delete crd poddisplays.demo.example.com` then re-run `run-local.sh`.
