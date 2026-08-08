#!/usr/bin/env bash
#
# create-crd-demo.sh
# ------------------
# Scaffolds a Kubernetes CRD demo with a live browser console:
#
#   PodDisplay (custom resource) -> Deployment -> ReplicaSet -> Pods
#   operator watches all four kinds and streams them to the browser
#   the console can scale, update the image, and drive rollouts
#
# Usage:  bash create-crd-demo.sh [target-directory]
#
set -euo pipefail

PROJECT="${1:-crd-pod-demo}"

if [ -e "$PROJECT" ]; then
  echo "!! '$PROJECT' already exists. Remove it or pass a different directory name."
  exit 1
fi

echo ">> creating project tree in ./$PROJECT"
mkdir -p "$PROJECT"
cd "$PROJECT"

mkdir -p manifests operator operator/static scripts

echo '   .gitignore'
cat > '.gitignore' <<'EOF_FILE'
.venv/
__pycache__/
*.pyc
EOF_FILE

echo '   Dockerfile'
cat > 'Dockerfile' <<'EOF_FILE'
FROM python:3.12-slim
WORKDIR /app
COPY operator/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY operator/ /app/
EXPOSE 8080
CMD ["python", "main.py"]
EOF_FILE

echo '   README.md'
cat > 'README.md' <<'EOF_FILE'
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
EOF_FILE

echo '   STEPS.md'
cat > 'STEPS.md' <<'EOF_FILE'
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
EOF_FILE

echo '   manifests/crd.yaml'
cat > 'manifests/crd.yaml' <<'EOF_FILE'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: poddisplays.demo.example.com
spec:
  group: demo.example.com
  scope: Namespaced
  names:
    kind: PodDisplay
    plural: poddisplays
    singular: poddisplay
    shortNames: [pd]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                image:
                  type: string
                  default: busybox:1.36
                  description: Container image for the managed deployment.
                replicas:
                  type: integer
                  default: 1
                  minimum: 0
                  maximum: 20
                  description: How many pods the deployment should run.
                message:
                  type: string
                  default: hello from PodDisplay
                  description: Text the pod prints, also shown on the dashboard.
                color:
                  type: string
                  enum: [cyan, amber, violet, lime]
                  default: cyan
                  description: Accent colour of the card on the dashboard.
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
      additionalPrinterColumns:
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: string
          jsonPath: .status.ready
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Deployment
          type: string
          jsonPath: .status.deployment
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
EOF_FILE

echo '   manifests/operator-deployment.yaml'
cat > 'manifests/operator-deployment.yaml' <<'EOF_FILE'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: poddisplay-operator
  namespace: crd-demo
spec:
  replicas: 1
  selector:
    matchLabels: { app: poddisplay-operator }
  template:
    metadata:
      labels: { app: poddisplay-operator }
    spec:
      serviceAccountName: poddisplay-operator
      containers:
        - name: operator
          image: poddisplay-operator:dev
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: poddisplay-ui
  namespace: crd-demo
spec:
  selector: { app: poddisplay-operator }
  ports:
    - port: 8080
      targetPort: 8080
EOF_FILE

echo '   manifests/rbac.yaml'
cat > 'manifests/rbac.yaml' <<'EOF_FILE'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: poddisplay-operator
  namespace: crd-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: poddisplay-operator
rules:
  - apiGroups: ["demo.example.com"]
    resources: ["poddisplays", "poddisplays/status", "poddisplays/scale"]
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets"]
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: poddisplay-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: poddisplay-operator
subjects:
  - kind: ServiceAccount
    name: poddisplay-operator
    namespace: crd-demo
EOF_FILE

echo '   manifests/sample-poddisplay.yaml'
cat > 'manifests/sample-poddisplay.yaml' <<'EOF_FILE'
apiVersion: demo.example.com/v1alpha1
kind: PodDisplay
metadata:
  name: hello-world
  namespace: crd-demo
spec:
  image: busybox:1.36
  replicas: 3
  message: "hello world from a custom resource"
  color: cyan
---
apiVersion: demo.example.com/v1alpha1
kind: PodDisplay
metadata:
  name: web-front
  namespace: crd-demo
spec:
  image: nginx:1.27-alpine
  replicas: 2
  message: "this one runs an nginx image"
  color: violet
EOF_FILE

echo '   operator/actions.py'
cat > 'operator/actions.py' <<'EOF_FILE'
"""Write operations the dashboard can perform.

If a deployment was created by a PodDisplay, scaling and image changes are
written to the custom resource instead of the deployment - that way the
operator stays the single writer and you can watch the whole loop run.
"""

import asyncio
import datetime

from kubernetes import client

import k8s

GROUP, VERSION, PLURAL = k8s.GROUP, k8s.VERSION, k8s.PLURAL


class ActionError(Exception):
    """Raised with a message that is safe to show in the UI."""


async def _read_deployment(namespace: str, name: str):
    try:
        return await asyncio.to_thread(
            k8s.apps().read_namespaced_deployment, name, namespace
        )
    except client.ApiException as exc:
        if exc.status == 404:
            raise ActionError(f"deployment {namespace}/{name} not found") from exc
        raise ActionError(exc.reason) from exc


def _owning_poddisplay(dep) -> str | None:
    for ref in dep.metadata.owner_references or []:
        if ref.kind == "PodDisplay":
            return ref.name
    return None


async def _patch_cr(namespace: str, name: str, spec_patch: dict) -> None:
    try:
        await asyncio.to_thread(
            k8s.custom().patch_namespaced_custom_object,
            GROUP, VERSION, namespace, PLURAL, name, {"spec": spec_patch},
        )
    except client.ApiException as exc:
        raise ActionError(f"could not patch poddisplay/{name}: {exc.reason}") from exc


async def _patch_deployment(namespace: str, name: str, patch: dict) -> None:
    try:
        await asyncio.to_thread(
            k8s.apps().patch_namespaced_deployment, name, namespace, patch
        )
    except client.ApiException as exc:
        raise ActionError(f"could not patch deployment/{name}: {exc.reason}") from exc


# ---------------------------------------------------------------------------
async def scale(namespace: str, name: str, replicas: int) -> str:
    if replicas < 0 or replicas > 50:
        raise ActionError("replicas must be between 0 and 50")

    dep = await _read_deployment(namespace, name)
    owner = _owning_poddisplay(dep)
    if owner:
        await _patch_cr(namespace, owner, {"replicas": replicas})
        return f"poddisplay/{owner} set to {replicas} replicas - operator is reconciling"

    await _patch_deployment(namespace, name, {"spec": {"replicas": replicas}})
    return f"deployment/{name} scaled to {replicas}"


async def set_image(namespace: str, name: str, container: str, image: str) -> str:
    image = (image or "").strip()
    if not image:
        raise ActionError("image cannot be empty")

    dep = await _read_deployment(namespace, name)
    names = [c.name for c in dep.spec.template.spec.containers]
    if container not in names:
        raise ActionError(f"container {container} is not in this deployment")

    owner = _owning_poddisplay(dep)
    if owner:
        await _patch_cr(namespace, owner, {"image": image})
        return f"poddisplay/{owner} image set to {image} - rollout starting"

    patch = {"spec": {"template": {"spec": {"containers": [
        {"name": container, "image": image}
    ]}}}}
    await _patch_deployment(namespace, name, patch)
    return f"deployment/{name} rolling out {image}"


async def restart(namespace: str, name: str) -> str:
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": stamp
    }}}}}
    await _patch_deployment(namespace, name, patch)
    return f"deployment/{name} restarting - every pod is replaced"


async def pause(namespace: str, name: str, paused: bool) -> str:
    await _patch_deployment(namespace, name, {"spec": {"paused": paused}})
    return f"deployment/{name} rollout {'paused' if paused else 'resumed'}"


async def undo(namespace: str, name: str) -> str:
    """Roll back to the pod template of the previous revision, like kubectl rollout undo."""
    dep = await _read_deployment(namespace, name)
    current = int((dep.metadata.annotations or {}).get(k8s.REVISION_ANNOTATION, 0) or 0)

    selector = ",".join(
        f"{k}={v}" for k, v in (dep.spec.selector.match_labels or {}).items()
    )
    try:
        rs_list = await asyncio.to_thread(
            k8s.apps().list_namespaced_replica_set, namespace, label_selector=selector
        )
    except client.ApiException as exc:
        raise ActionError(exc.reason) from exc

    def revision(rs) -> int:
        return int((rs.metadata.annotations or {}).get(k8s.REVISION_ANNOTATION, 0) or 0)

    previous = [rs for rs in rs_list.items if 0 < revision(rs) < current]
    if not previous:
        raise ActionError("there is no earlier revision to roll back to")

    target = max(previous, key=revision)
    template = k8s.serialize(target.spec.template)
    template.get("metadata", {}).get("labels", {}).pop("pod-template-hash", None)

    await _patch_deployment(namespace, name, {"spec": {"template": template}})
    return f"deployment/{name} rolling back to revision {revision(target)}"


# ---------------------------------------------------------------------------
async def create_poddisplay(
    namespace: str, name: str, image: str, replicas: int, message: str, color: str
) -> str:
    body = {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "PodDisplay",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "image": image,
            "replicas": replicas,
            "message": message,
            "color": color,
        },
    }
    try:
        await asyncio.to_thread(
            k8s.custom().create_namespaced_custom_object,
            GROUP, VERSION, namespace, PLURAL, body,
        )
    except client.ApiException as exc:
        if exc.status == 409:
            raise ActionError(f"poddisplay/{name} already exists") from exc
        raise ActionError(exc.reason) from exc
    return f"poddisplay/{name} created - watch the deployment appear"


async def delete_poddisplay(namespace: str, name: str) -> str:
    try:
        await asyncio.to_thread(
            k8s.custom().delete_namespaced_custom_object,
            GROUP, VERSION, namespace, PLURAL, name,
        )
    except client.ApiException as exc:
        raise ActionError(exc.reason) from exc
    return f"poddisplay/{name} deleted - deployment and pods follow"
EOF_FILE

echo '   operator/broker.py'
cat > 'operator/broker.py' <<'EOF_FILE'
"""In-memory fan-out between the Kubernetes watches and every open browser tab.

Holds the current view of four kinds - poddisplays, deployments, replicasets and
pods - and pushes every change to all subscribers as a server-sent event.
"""

import asyncio
from typing import Any, Dict, List

KINDS = ("poddisplays", "deployments", "replicasets", "pods")


class EventBroker:
    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue] = set()
        self._objects: Dict[str, Dict[str, dict]] = {k: {} for k in KINDS}

    # ---- browser side -----------------------------------------------------
    def subscribe(self) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=4000)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        self._subscribers.discard(queue)

    def snapshot(self) -> Dict[str, List[dict]]:
        return {
            kind: sorted(
                objs.values(), key=lambda o: o.get("created") or "", reverse=True
            )
            for kind, objs in self._objects.items()
        }

    def counts(self) -> Dict[str, int]:
        return {kind: len(objs) for kind, objs in self._objects.items()}

    @property
    def viewers(self) -> int:
        return len(self._subscribers)

    # ---- cluster side -----------------------------------------------------
    async def publish(self, kind: str, event_type: str, obj: dict) -> None:
        if kind not in self._objects:
            return
        key = f"{obj['namespace']}/{obj['name']}"
        if event_type == "DELETED":
            self._objects[kind].pop(key, None)
        else:
            self._objects[kind][key] = obj

        message: Dict[str, Any] = {"kind": kind, "type": event_type, "obj": obj}
        for queue in list(self._subscribers):
            try:
                queue.put_nowait(message)
            except asyncio.QueueFull:
                self._subscribers.discard(queue)

    async def notify(self, level: str, text: str) -> None:
        """Push a one-off toast line to every tab (used for action results)."""
        message = {"kind": "notice", "level": level, "text": text}
        for queue in list(self._subscribers):
            try:
                queue.put_nowait(message)
            except asyncio.QueueFull:
                self._subscribers.discard(queue)


broker = EventBroker()
EOF_FILE

echo '   operator/controller.py'
cat > 'operator/controller.py' <<'EOF_FILE'
"""PodDisplay controller.

Reconcile:  PodDisplay custom resource  ->  Deployment  ->  ReplicaSet  ->  Pods
Observe:    every deployment, replicaset and pod in the cluster is streamed to
            the dashboard, so scaling and rollouts are visible as they happen.
"""

import asyncio
import logging

import kopf
from kubernetes import client

import k8s
from broker import broker

GROUP, VERSION, PLURAL = k8s.GROUP, k8s.VERSION, k8s.PLURAL
MANAGED_BY = k8s.MANAGED_BY

log = logging.getLogger("poddisplay")


@kopf.on.startup()
async def startup(settings: kopf.OperatorSettings, **_):
    settings.posting.level = logging.INFO
    settings.watching.server_timeout = 300
    settings.persistence.finalizer = "poddisplays.demo.example.com/finalizer"


# --------------------------------------------------------------------------
# reconcile: PodDisplay -> Deployment
# --------------------------------------------------------------------------
def container_command(image: str, message: str):
    """busybox-style images get a print loop; real images keep their entrypoint."""
    base = (image or "").split(":")[0].split("/")[-1]
    if base in ("busybox", "alpine", "bash", "sh"):
        safe = message.replace("\\", "").replace('"', "'").replace("$", "")
        return ["/bin/sh", "-c"], [f'while true; do echo "{safe}"; sleep 10; done']
    return None, None


def build_deployment(name: str, spec: dict) -> dict:
    image = spec.get("image") or "busybox:1.36"
    replicas = int(spec.get("replicas", 1))
    message = spec.get("message") or f"hello from {name}"
    color = spec.get("color") or "cyan"

    labels = {
        "app.kubernetes.io/managed-by": MANAGED_BY,
        "demo.example.com/poddisplay": name,
    }
    annotations = {
        "demo.example.com/message": message,
        "demo.example.com/color": color,
    }
    command, args = container_command(image, message)
    container = {
        "name": "display",
        "image": image,
        "resources": {
            "requests": {"cpu": "10m", "memory": "16Mi"},
            "limits": {"cpu": "200m", "memory": "128Mi"},
        },
    }
    if command:
        container["command"] = command
        container["args"] = args

    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": name, "labels": labels, "annotations": annotations},
        "spec": {
            "replicas": replicas,
            "revisionHistoryLimit": 5,
            "selector": {"matchLabels": {"demo.example.com/poddisplay": name}},
            "strategy": {
                "type": "RollingUpdate",
                "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0},
            },
            "template": {
                "metadata": {"labels": labels, "annotations": annotations},
                "spec": {
                    "terminationGracePeriodSeconds": 2,
                    "containers": [container],
                },
            },
        },
    }


@kopf.on.create(GROUP, VERSION, PLURAL)
@kopf.on.update(GROUP, VERSION, PLURAL, field="spec")
@kopf.on.resume(GROUP, VERSION, PLURAL)
async def reconcile(spec, name, namespace, patch, logger, **_):
    body = build_deployment(name, dict(spec))
    kopf.adopt(body)  # owner reference -> deployment dies with the custom resource
    api = k8s.apps()
    try:
        await asyncio.to_thread(api.create_namespaced_deployment, namespace, body)
        logger.info("created deployment %s/%s", namespace, name)
        patch.status["phase"] = "Created"
    except client.ApiException as exc:
        if exc.status != 409:
            raise kopf.TemporaryError(f"create failed: {exc.reason}", delay=10)
        await asyncio.to_thread(
            api.patch_namespaced_deployment, name, namespace, body
        )
        logger.info("updated deployment %s/%s", namespace, name)
        patch.status["phase"] = "Updated"

    patch.status["deployment"] = name
    patch.status["replicas"] = int(spec.get("replicas", 1))
    return {"deployment": name}


@kopf.on.delete(GROUP, VERSION, PLURAL)
async def on_delete(name, namespace, logger, **_):
    try:
        await asyncio.to_thread(
            k8s.apps().delete_namespaced_deployment, name, namespace
        )
    except client.ApiException as exc:
        if exc.status != 404:
            raise
    logger.info("removed deployment for %s/%s", namespace, name)


# --------------------------------------------------------------------------
# keep the custom resource status in step with its deployment
# --------------------------------------------------------------------------
@kopf.on.event("apps", "v1", "deployments", labels={"app.kubernetes.io/managed-by": MANAGED_BY})
async def mirror_status(body, event, **_):
    if (event.get("type") or "ADDED") == "DELETED":
        return
    dep = k8s.summarize_deployment(dict(body))
    if not dep["owner"]:
        return
    status = {
        "ready": f"{dep['ready']}/{dep['replicas']}",
        "replicas": dep["current"],
        "rollout": dep["rollout"],
        "revision": dep["revision"],
    }
    try:
        await asyncio.to_thread(
            k8s.custom().patch_namespaced_custom_object_status,
            GROUP, VERSION, dep["namespace"], PLURAL, dep["owner"],
            {"status": status},
        )
    except client.ApiException as exc:
        if exc.status not in (404, 409):
            log.warning("status mirror failed: %s", exc.reason)


# --------------------------------------------------------------------------
# observe: stream everything to the dashboard
# --------------------------------------------------------------------------
@kopf.on.event(GROUP, VERSION, PLURAL)
async def watch_poddisplays(event, body, **_):
    await broker.publish(
        "poddisplays", event.get("type") or "ADDED", k8s.summarize_poddisplay(dict(body))
    )


@kopf.on.event("apps", "v1", "deployments")
async def watch_deployments(event, body, **_):
    await broker.publish(
        "deployments", event.get("type") or "ADDED", k8s.summarize_deployment(dict(body))
    )


@kopf.on.event("apps", "v1", "replicasets")
async def watch_replicasets(event, body, **_):
    await broker.publish(
        "replicasets", event.get("type") or "ADDED", k8s.summarize_replicaset(dict(body))
    )


@kopf.on.event("", "v1", "pods")
async def watch_pods(event, body, **_):
    await broker.publish(
        "pods", event.get("type") or "ADDED", k8s.summarize_pod(dict(body))
    )
EOF_FILE

echo '   operator/k8s.py'
cat > 'operator/k8s.py' <<'EOF_FILE'
"""Kubernetes clients and the summarizers that turn API objects into UI rows."""

import logging
from typing import Optional

from kubernetes import client, config

GROUP = "demo.example.com"
VERSION = "v1alpha1"
PLURAL = "poddisplays"
MANAGED_BY = "poddisplay-operator"
REVISION_ANNOTATION = "deployment.kubernetes.io/revision"

log = logging.getLogger("poddisplay.k8s")
_loaded = False


def _load() -> None:
    global _loaded
    if not _loaded:
        try:
            config.load_incluster_config()
            log.info("using in-cluster credentials")
        except config.ConfigException:
            config.load_kube_config()
            log.info("using local kubeconfig")
        _loaded = True


def core() -> client.CoreV1Api:
    _load()
    return client.CoreV1Api()


def apps() -> client.AppsV1Api:
    _load()
    return client.AppsV1Api()


def custom() -> client.CustomObjectsApi:
    _load()
    return client.CustomObjectsApi()


def serialize(obj) -> dict:
    return client.ApiClient().sanitize_for_serialization(obj)


# ---------------------------------------------------------------------------
# summarizers
# ---------------------------------------------------------------------------
def _owner(meta: dict, kind: str) -> Optional[str]:
    for ref in meta.get("ownerReferences") or []:
        if ref.get("kind") == kind:
            return ref.get("name")
    return None


def rollout_state(spec: dict, status: dict, meta: dict) -> str:
    desired = spec.get("replicas", 0) or 0
    updated = status.get("updatedReplicas") or 0
    ready = status.get("readyReplicas") or 0
    available = status.get("availableReplicas") or 0
    current = status.get("replicas") or 0

    if spec.get("paused"):
        return "Paused"
    for cond in status.get("conditions") or []:
        if cond.get("type") == "Progressing" and cond.get("reason") == "ProgressDeadlineExceeded":
            return "Failed"
    if (status.get("observedGeneration") or 0) < (meta.get("generation") or 0):
        return "Pending"
    if desired == 0:
        return "Scaled to zero"
    if updated < desired:
        return "Rolling out"
    if current > updated:
        return "Retiring old pods"
    if available < desired or ready < desired:
        return "Waiting for pods"
    return "Complete"


def summarize_deployment(body: dict) -> dict:
    meta = body.get("metadata") or {}
    spec = body.get("spec") or {}
    status = body.get("status") or {}
    template = (spec.get("template") or {}).get("spec") or {}
    annotations = meta.get("annotations") or {}
    labels = meta.get("labels") or {}

    return {
        "kind": "Deployment",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "uid": meta.get("uid"),
        "created": meta.get("creationTimestamp"),
        "replicas": spec.get("replicas", 0),
        "ready": status.get("readyReplicas") or 0,
        "updated": status.get("updatedReplicas") or 0,
        "available": status.get("availableReplicas") or 0,
        "current": status.get("replicas") or 0,
        "unavailable": status.get("unavailableReplicas") or 0,
        "paused": bool(spec.get("paused")),
        "revision": annotations.get(REVISION_ANNOTATION),
        "strategy": (spec.get("strategy") or {}).get("type", "RollingUpdate"),
        "containers": [
            {"name": c.get("name"), "image": c.get("image")}
            for c in template.get("containers") or []
        ],
        "owner": _owner(meta, "PodDisplay"),
        "managed": labels.get("app.kubernetes.io/managed-by") == MANAGED_BY,
        "message": annotations.get("demo.example.com/message"),
        "color": annotations.get("demo.example.com/color") or "cyan",
        "rollout": rollout_state(spec, status, meta),
        "deleting": bool(meta.get("deletionTimestamp")),
    }


def summarize_replicaset(body: dict) -> dict:
    meta = body.get("metadata") or {}
    spec = body.get("spec") or {}
    status = body.get("status") or {}
    template = (spec.get("template") or {}).get("spec") or {}
    annotations = meta.get("annotations") or {}
    labels = meta.get("labels") or {}

    desired = spec.get("replicas", 0) or 0
    return {
        "kind": "ReplicaSet",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "uid": meta.get("uid"),
        "created": meta.get("creationTimestamp"),
        "replicas": desired,
        "current": status.get("replicas") or 0,
        "ready": status.get("readyReplicas") or 0,
        "available": status.get("availableReplicas") or 0,
        "revision": annotations.get(REVISION_ANNOTATION),
        "owner": _owner(meta, "Deployment"),
        "images": [c.get("image") for c in template.get("containers") or []],
        "active": desired > 0,
        "app": labels.get("demo.example.com/poddisplay"),
        "managed": labels.get("app.kubernetes.io/managed-by") == MANAGED_BY,
        "deleting": bool(meta.get("deletionTimestamp")),
    }


def summarize_pod(body: dict) -> dict:
    meta = body.get("metadata") or {}
    spec = body.get("spec") or {}
    status = body.get("status") or {}
    statuses = status.get("containerStatuses") or []
    labels = meta.get("labels") or {}
    annotations = meta.get("annotations") or {}

    waiting = next(
        (
            (c.get("state") or {}).get("waiting", {}).get("reason")
            for c in statuses
            if (c.get("state") or {}).get("waiting")
        ),
        None,
    )
    return {
        "kind": "Pod",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "uid": meta.get("uid"),
        "created": meta.get("creationTimestamp"),
        "phase": waiting or status.get("phase") or "Unknown",
        "node": spec.get("nodeName"),
        "podIP": status.get("podIP"),
        "images": [c.get("image") for c in spec.get("containers") or []],
        "ready": sum(1 for c in statuses if c.get("ready")),
        "total": len(spec.get("containers") or []),
        "restarts": sum(c.get("restartCount", 0) for c in statuses),
        "owner": _owner(meta, "ReplicaSet"),
        "app": labels.get("demo.example.com/poddisplay"),
        "managed": labels.get("app.kubernetes.io/managed-by") == MANAGED_BY,
        "message": annotations.get("demo.example.com/message"),
        "color": annotations.get("demo.example.com/color") or "cyan",
        "deleting": bool(meta.get("deletionTimestamp")),
    }


def summarize_poddisplay(body: dict) -> dict:
    meta = body.get("metadata") or {}
    spec = body.get("spec") or {}
    status = body.get("status") or {}
    return {
        "kind": "PodDisplay",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "uid": meta.get("uid"),
        "created": meta.get("creationTimestamp"),
        "image": spec.get("image"),
        "replicas": spec.get("replicas", 1),
        "message": spec.get("message"),
        "color": spec.get("color") or "cyan",
        "deployment": status.get("deployment"),
        "phase": status.get("phase") or "Unknown",
        "managed": True,
        "deleting": bool(meta.get("deletionTimestamp")),
    }
EOF_FILE

echo '   operator/main.py'
cat > 'operator/main.py' <<'EOF_FILE'
"""Runs the kopf operator and the web server in one asyncio process."""

import asyncio
import logging
import os

import kopf
import uvicorn

import controller  # noqa: F401  - importing registers the kopf handlers
from web import app


async def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = uvicorn.Server(
        uvicorn.Config(app, host="0.0.0.0", port=port, log_level="warning")
    )
    print(f"\n  dashboard -> http://localhost:{port}\n", flush=True)
    await asyncio.gather(
        kopf.operator(clusterwide=True, standalone=True),
        server.serve(),
    )


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    )
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("bye")
EOF_FILE

echo '   operator/requirements.txt'
cat > 'operator/requirements.txt' <<'EOF_FILE'
kopf>=1.37,<2
kubernetes>=29
fastapi>=0.110
uvicorn[standard]>=0.29
EOF_FILE

echo '   operator/static/app.js'
cat > 'operator/static/app.js' <<'EOF_FILE'
/* PodDisplay console -------------------------------------------------------
   Every render patches existing DOM nodes in place instead of rebuilding the
   page, so the one-second age tick never causes a repaint or a flicker.
--------------------------------------------------------------------------- */

const state = {
  poddisplays: new Map(),
  deployments: new Map(),
  replicasets: new Map(),
  pods: new Map(),
};
const seenAt   = new Map();   // "kind:ns/name" -> ms this tab first saw it
const depCards = new Map();
const podCards = new Map();
const rsGroups = new Map();

const $ = id => document.getElementById(id);
const keyOf = o => o.namespace + '/' + o.name;

const ACCENT = { cyan: '#35d6e6', amber: '#ffb545', violet: '#9d7bff', lime: '#a3e635' };
const ROLLOUT_ACCENT = {
  'Failed': '#ff6b81', 'Rolling out': '#ffb545', 'Pending': '#ffb545',
  'Waiting for pods': '#ffb545', 'Retiring old pods': '#ffb545', 'Paused': '#9d7bff',
};

/* ---------- small helpers ---------- */
function age(iso) {
  if (!iso) return '—';
  const s = Math.max(0, Math.floor((Date.now() - new Date(iso)) / 1000));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
  if (s < 86400) return Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm';
  return Math.floor(s / 86400) + 'd';
}

function setText(node, value) {
  if (node && node.textContent !== value) node.textContent = value;
}

function setInput(node, value) {
  if (!node || node.dataset.dirty || document.activeElement === node) return;
  if (node.value !== String(value)) node.value = value;
}

function toast(level, text) {
  const el = document.createElement('div');
  el.className = 'toast' + (level === 'error' ? ' error' : '');
  el.textContent = text;
  $('toasts').append(el);
  setTimeout(() => el.remove(), 6000);
}

async function api(method, url, body) {
  try {
    const res = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return res.ok;   // the operator broadcasts the result as a notice event
  } catch (err) {
    toast('error', 'could not reach the operator: ' + err.message);
    return false;
  }
}

/* ---------- filtering ---------- */
function matches(o) {
  if ($('only-managed').checked && !o.managed) return false;
  const q = $('filter').value.trim().toLowerCase();
  return !q || (o.name + ' ' + o.namespace).toLowerCase().includes(q);
}

function listOf(kind) {
  return [...state[kind].values()]
    .filter(matches)
    .sort((a, b) => (b.created || '').localeCompare(a.created || ''));
}

function isFresh(kind, o) {
  return Date.now() - (seenAt.get(kind + ':' + keyOf(o)) || 0) < 12000;
}

/* keeps a container's children in the order of `items`, reusing nodes */
function sync(container, items, cache, build, fill) {
  const wanted = new Set(items.map(keyOf));
  for (const [k, c] of cache) {
    if (!wanted.has(k)) { c.el.remove(); cache.delete(k); }
  }
  items.forEach((item, i) => {
    const k = keyOf(item);
    let c = cache.get(k);
    if (!c) { c = build(item); cache.set(k, c); }
    fill(c, item);
    if (container.children[i] !== c.el) {
      container.insertBefore(c.el, container.children[i] || null);
    }
  });
}

/* ---------- deployments ---------- */
function buildDeploymentCard(d) {
  const el = document.createElement('article');
  el.className = 'card enter';
  el.addEventListener('animationend', () => el.classList.remove('enter'), { once: true });
  el.innerHTML =
    '<header><div><div class="ns"></div><div class="name"></div></div>' +
    '<span class="badge" data-f="rollout"></span></header>' +
    '<div class="pips"></div>' +
    '<div class="legend"><span data-f="counts"></span><span data-f="rev"></span></div>' +
    '<div class="row"><span>image</span><span data-f="image"></span></div>' +
    '<div class="row"><span>strategy</span><span data-f="strategy"></span></div>' +
    '<div class="row"><span>source</span><span data-f="source"></span></div>' +
    '<div class="row"><span>age</span><span data-f="age"></span></div>' +
    '<div class="msg" data-f="msg"></div>' +
    '<div class="controls">' +
      '<div class="ctl-row"><label>replica count</label>' +
        '<button class="step" data-a="dec" title="one fewer">−</button>' +
        '<input class="replicas" type="number" min="0" max="50" data-f="replicas" />' +
        '<button class="step" data-a="inc" title="one more">+</button>' +
        '<button class="primary" data-a="scale">Apply</button>' +
        '<span class="hint" data-f="scalehint"></span>' +
      '</div>' +
      '<div class="ctl-row"><label>container image</label>' +
        '<input class="image" type="text" data-f="imageinput" placeholder="repo/name:tag" />' +
        '<button data-a="image">Update image</button>' +
      '</div>' +
      '<div class="ctl-row"><label>rollout</label>' +
        '<button data-a="restart" title="replace every pod">Restart</button>' +
        '<button class="warn" data-a="pause"></button>' +
        '<button data-a="undo" title="back to the previous revision">Undo</button>' +
        '<button class="danger" data-a="delete">Delete</button>' +
      '</div>' +
    '</div>';

  const c = {
    el,
    ns: el.querySelector('.ns'),
    name: el.querySelector('.name'),
    rollout: el.querySelector('[data-f=rollout]'),
    pips: el.querySelector('.pips'),
    counts: el.querySelector('[data-f=counts]'),
    rev: el.querySelector('[data-f=rev]'),
    image: el.querySelector('[data-f=image]'),
    strategy: el.querySelector('[data-f=strategy]'),
    source: el.querySelector('[data-f=source]'),
    age: el.querySelector('[data-f=age]'),
    msg: el.querySelector('[data-f=msg]'),
    replicas: el.querySelector('[data-f=replicas]'),
    scalehint: el.querySelector('[data-f=scalehint]'),
    imageinput: el.querySelector('[data-f=imageinput]'),
    pause: el.querySelector('[data-a=pause]'),
    del: el.querySelector('[data-a=delete]'),
    data: d,
  };

  c.replicas.addEventListener('input', () => { c.replicas.dataset.dirty = '1'; });
  c.imageinput.addEventListener('input', () => { c.imageinput.dataset.dirty = '1'; });

  el.addEventListener('click', async ev => {
    const action = ev.target.dataset && ev.target.dataset.a;
    if (!action) return;
    const d2 = c.data;
    const base = `/api/deployments/${d2.namespace}/${d2.name}`;

    if (action === 'inc' || action === 'dec') {
      const next = Math.max(0, (parseInt(c.replicas.value, 10) || 0) + (action === 'inc' ? 1 : -1));
      c.replicas.value = next;
      c.replicas.dataset.dirty = '1';
      return;
    }
    if (action === 'scale') {
      const replicas = parseInt(c.replicas.value, 10);
      if (Number.isNaN(replicas)) return toast('error', 'replica count must be a number');
      if (await api('POST', base + '/scale', { replicas })) delete c.replicas.dataset.dirty;
      return;
    }
    if (action === 'image') {
      const image = c.imageinput.value.trim();
      const container = (d2.containers[0] || {}).name || 'display';
      if (await api('POST', base + '/image', { container, image })) delete c.imageinput.dataset.dirty;
      return;
    }
    if (action === 'restart') return void api('POST', base + '/restart');
    if (action === 'undo')    return void api('POST', base + '/undo');
    if (action === 'pause')   return void api('POST', base + '/pause', { paused: !d2.paused });
    if (action === 'delete') {
      if (!d2.owner) return;
      if (!confirm(`Delete poddisplay/${d2.owner}? Its deployment and pods go with it.`)) return;
      return void api('DELETE', `/api/poddisplays/${d2.namespace}/${d2.owner}`);
    }
  });

  return c;
}

function fillPips(container, d) {
  const total = Math.min(60, Math.max(d.replicas || 0, d.current || 0));
  while (container.childElementCount > total) container.lastElementChild.remove();
  while (container.childElementCount < total) {
    container.append(Object.assign(document.createElement('i'), { className: 'pip' }));
  }
  [...container.children].forEach((pip, i) => {
    const cls = i < d.ready ? 'pip ready' : (i < d.replicas ? 'pip starting' : 'pip surplus');
    if (pip.className !== cls) pip.className = cls;
  });
}

function fillDeploymentCard(c, d) {
  c.data = d;
  const accent = ROLLOUT_ACCENT[d.rollout] || ACCENT[d.color] || ACCENT.cyan;
  if (c.el.style.getPropertyValue('--accent') !== accent) c.el.style.setProperty('--accent', accent);

  setText(c.ns, d.namespace);
  setText(c.name, d.name);
  setText(c.rollout, d.rollout);
  fillPips(c.pips, d);
  setText(c.counts, `${d.ready} ready · ${d.updated} updated · ${d.available} available · ${d.replicas} desired`);
  setText(c.rev, d.revision ? 'revision ' + d.revision : '');
  setText(c.image, d.containers.map(x => x.image).join(', ') || '—');
  setText(c.strategy, d.strategy + (d.paused ? ' · paused' : ''));
  setText(c.source, d.owner ? 'PodDisplay/' + d.owner : 'created directly');
  setText(c.age, age(d.created));
  c.msg.hidden = !d.message;
  setText(c.msg, d.message || '');

  setInput(c.replicas, d.replicas);
  setInput(c.imageinput, (d.containers[0] || {}).image || '');
  setText(c.scalehint, d.owner ? 'writes spec.replicas on the custom resource' : 'writes the deployment');
  setText(c.pause, d.paused ? 'Resume' : 'Pause');
  c.del.disabled = !d.owner;
  c.del.title = d.owner ? '' : 'only poddisplay-owned deployments can be deleted here';

  c.el.classList.toggle('going', !!d.deleting);
  c.el.classList.toggle('fresh', isFresh('deployments', d));
}

function renderDeployments() {
  const deps = listOf('deployments');
  $('dep-empty').hidden = deps.length > 0;
  sync($('dep-grid'), deps, depCards, buildDeploymentCard, fillDeploymentCard);
}

/* ---------- replicasets ---------- */
function buildGroup() {
  const el = document.createElement('section');
  el.className = 'group';
  el.innerHTML = '<h3><span data-f="title"></span><small data-f="sub"></small></h3><div data-f="rows"></div>';
  return {
    el,
    title: el.querySelector('[data-f=title]'),
    sub: el.querySelector('[data-f=sub]'),
    rows: el.querySelector('[data-f=rows]'),
    cache: new Map(),
  };
}

function buildRsRow() {
  const el = document.createElement('div');
  el.className = 'rs';
  el.innerHTML =
    '<span class="rev" data-f="rev"></span>' +
    '<span class="rs-name" data-f="name"></span>' +
    '<span data-f="count"></span>' +
    '<span class="rs-images" data-f="images"></span>' +
    '<span class="tag" data-f="tag"></span>';
  return {
    el,
    rev: el.querySelector('[data-f=rev]'),
    name: el.querySelector('[data-f=name]'),
    count: el.querySelector('[data-f=count]'),
    images: el.querySelector('[data-f=images]'),
    tag: el.querySelector('[data-f=tag]'),
  };
}

function renderReplicaSets() {
  const sets = listOf('replicasets');
  $('rs-empty').hidden = sets.length > 0;

  const byDeployment = new Map();
  for (const rs of sets) {
    const owner = rs.owner || '(no deployment)';
    const k = rs.namespace + '/' + owner;
    if (!byDeployment.has(k)) byDeployment.set(k, []);
    byDeployment.get(k).push(rs);
  }

  const groups = [...byDeployment.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  const container = $('rs-groups');

  for (const [k, g] of rsGroups) {
    if (!byDeployment.has(k)) { g.el.remove(); rsGroups.delete(k); }
  }

  groups.forEach(([k, rows], i) => {
    let g = rsGroups.get(k);
    if (!g) { g = buildGroup(); rsGroups.set(k, g); }

    const [namespace, owner] = [k.slice(0, k.indexOf('/')), k.slice(k.indexOf('/') + 1)];
    const dep = state.deployments.get(k);
    const active = rows.filter(r => r.active).length;
    setText(g.title, owner);
    setText(g.sub, `${namespace} · ${rows.length} replicaset${rows.length === 1 ? '' : 's'} · ${active} active · ${rows.length - active} kept as history`);

    rows.sort((a, b) => (parseInt(b.revision, 10) || 0) - (parseInt(a.revision, 10) || 0));
    sync(g.rows, rows, g.cache, buildRsRow, (c, rs) => {
      const current = dep && String(dep.revision) === String(rs.revision);
      setText(c.rev, rs.revision ? 'rev ' + rs.revision : '—');
      setText(c.name, rs.name);
      setText(c.count, `${rs.ready}/${rs.replicas} ready`);
      setText(c.images, (rs.images || []).join(', '));
      setText(c.tag, current ? 'current' : (rs.active ? 'active' : 'history'));
      c.el.className = 'rs' + (current ? ' current' : (rs.active ? '' : ' history'));
    });

    if (container.children[i] !== g.el) container.insertBefore(g.el, container.children[i] || null);
  });
}

/* ---------- pods ---------- */
function buildPodCard() {
  const el = document.createElement('article');
  el.className = 'card enter';
  el.addEventListener('animationend', () => el.classList.remove('enter'), { once: true });
  el.innerHTML =
    '<div class="ns"></div><div class="name"></div>' +
    '<div class="row"><span>state</span><span class="badge" data-f="phase"></span></div>' +
    '<div class="row"><span>ready</span><span data-f="ready"></span></div>' +
    '<div class="row"><span>image</span><span data-f="image"></span></div>' +
    '<div class="row"><span>node</span><span data-f="node"></span></div>' +
    '<div class="row"><span>pod ip</span><span data-f="ip"></span></div>' +
    '<div class="row"><span>replicaset</span><span data-f="owner"></span></div>' +
    '<div class="row"><span>age</span><span data-f="age"></span></div>' +
    '<div class="msg" data-f="msg"></div>';
  return {
    el,
    ns: el.querySelector('.ns'),
    name: el.querySelector('.name'),
    phase: el.querySelector('[data-f=phase]'),
    ready: el.querySelector('[data-f=ready]'),
    image: el.querySelector('[data-f=image]'),
    node: el.querySelector('[data-f=node]'),
    ip: el.querySelector('[data-f=ip]'),
    owner: el.querySelector('[data-f=owner]'),
    age: el.querySelector('[data-f=age]'),
    msg: el.querySelector('[data-f=msg]'),
  };
}

function fillPodCard(c, p) {
  const bad = ['Failed', 'CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull'].includes(p.phase);
  const accent = bad ? '#ff6b81'
    : p.phase === 'Pending' ? '#ffb545'
    : (ACCENT[p.color] || ACCENT.cyan);
  if (c.el.style.getPropertyValue('--accent') !== accent) c.el.style.setProperty('--accent', accent);

  setText(c.ns, p.namespace);
  setText(c.name, p.name);
  setText(c.phase, p.deleting ? 'Terminating' : p.phase);
  setText(c.ready, `${p.ready}/${p.total} · ${p.restarts} restarts`);
  setText(c.image, (p.images || []).join(', ') || '—');
  setText(c.node, p.node || 'unscheduled');
  setText(c.ip, p.podIP || '—');
  setText(c.owner, p.owner || '—');
  setText(c.age, age(p.created));
  c.msg.hidden = !p.message;
  setText(c.msg, p.message || '');
  c.el.classList.toggle('going', !!p.deleting);
  c.el.classList.toggle('fresh', isFresh('pods', p));
}

function renderPods() {
  const pods = listOf('pods');
  $('pod-empty').hidden = pods.length > 0;
  sync($('pod-grid'), pods, podCards, buildPodCard, fillPodCard);
}

/* ---------- overview ---------- */
let lastRollouts = '';

function renderOverview() {
  const deps = listOf('deployments');
  const sets = listOf('replicasets');
  const pods = listOf('pods');
  const crs  = listOf('poddisplays');

  const desired = deps.reduce((n, d) => n + (d.replicas || 0), 0);
  const ready   = deps.reduce((n, d) => n + (d.ready || 0), 0);
  const activeRs = sets.filter(r => r.active).length;
  const runningPods = pods.filter(p => p.phase === 'Running').length;
  const rolling = deps.filter(d => !['Complete', 'Scaled to zero'].includes(d.rollout));

  setText($('ov-crs'), String(crs.length));
  setText($('ov-crs-sub'), crs.reduce((n, c) => n + (c.replicas || 0), 0) + ' replicas requested');
  setText($('ov-deps'), String(deps.length));
  setText($('ov-deps-sub'), rolling.length + ' mid-rollout · ' + (deps.length - rolling.length) + ' settled');
  setText($('ov-rs'), String(sets.length));
  setText($('ov-rs-sub'), activeRs + ' active · ' + (sets.length - activeRs) + ' kept as rollout history');
  setText($('ov-pods'), String(pods.length));
  setText($('ov-pods-sub'), runningPods + ' running · ' + (pods.length - runningPods) + ' other');
  setText($('ov-replicas'), ready + '/' + desired);

  const html = rolling.length
    ? rolling.map(d =>
        `<div class="card" style="--accent:${ROLLOUT_ACCENT[d.rollout] || ACCENT.cyan}">
           <header><div><div class="ns">${d.namespace}</div><div class="name">${d.name}</div></div>
           <span class="badge">${d.rollout}</span></header>
           <div class="legend">${d.updated}/${d.replicas} updated · ${d.ready} ready · revision ${d.revision || '—'}</div>
         </div>`).join('')
    : '<div class="empty">Every deployment has settled. Change a replica count or an image on the Deployments page and this fills up.</div>';
  if (html !== lastRollouts) { $('ov-rollouts').innerHTML = html; lastRollouts = html; }

  setText($('tab-deployments'), String(deps.length));
  setText($('tab-replicasets'), String(sets.length));
  setText($('tab-pods'), String(pods.length));
}

/* ---------- render + router ---------- */
function renderAll() {
  renderOverview();
  renderDeployments();
  renderReplicaSets();
  renderPods();
}

function route() {
  const page = (location.hash.replace('#/', '') || 'overview');
  const known = ['overview', 'deployments', 'replicasets', 'pods'];
  const active = known.includes(page) ? page : 'overview';
  known.forEach(p => { $('page-' + p).hidden = p !== active; });
  document.querySelectorAll('nav.tabs a').forEach(a => {
    a.classList.toggle('active', a.dataset.page === active);
  });
}

/* ---------- live stream ---------- */
function addLog(kind, type, obj) {
  const line = document.createElement('div');
  line.innerHTML =
    '<span class="t">' + new Date().toLocaleTimeString() + '</span>' +
    '<span class="' + type + '">' + type.padEnd(9) + '</span> ' +
    kind.replace(/s$/, '').padEnd(12) + ' ' + obj.namespace + '/' + obj.name;
  $('log').prepend(line);
  while ($('log').childElementCount > 150) $('log').lastElementChild.remove();
}

const es = new EventSource('/api/events');

es.onopen  = () => { $('dot').classList.add('live');    setText($('conn'), 'watching the cluster'); };
es.onerror = () => { $('dot').classList.remove('live'); setText($('conn'), 'operator unreachable — retrying'); };

es.addEventListener('snapshot', ev => {
  const data = JSON.parse(ev.data);
  for (const kind of Object.keys(state)) {
    state[kind].clear();
    (data[kind] || []).forEach(o => {
      state[kind].set(keyOf(o), o);
      seenAt.set(kind + ':' + keyOf(o), 0);
    });
  }
  renderAll();
});

es.addEventListener('change', ev => {
  const { kind, type, obj } = JSON.parse(ev.data);
  if (!state[kind]) return;
  const k = kind + ':' + keyOf(obj);
  if (type === 'DELETED') {
    state[kind].delete(keyOf(obj));
    seenAt.delete(k);
  } else {
    if (!state[kind].has(keyOf(obj))) seenAt.set(k, Date.now());
    state[kind].set(keyOf(obj), obj);
  }
  if (matches(obj)) addLog(kind, type, obj);
  renderAll();
});

es.addEventListener('notice', ev => {
  const n = JSON.parse(ev.data);
  toast(n.level, n.text);
});

/* ---------- wiring ---------- */
$('only-managed').addEventListener('change', renderAll);
$('filter').addEventListener('input', renderAll);
window.addEventListener('hashchange', route);

$('nf-create').addEventListener('click', async () => {
  const name = $('nf-name').value.trim();
  if (!name) return toast('error', 'give the poddisplay a name');
  await api('POST', '/api/poddisplays', {
    name,
    namespace: 'crd-demo',
    image: $('nf-image').value.trim() || 'busybox:1.36',
    replicas: parseInt($('nf-replicas').value, 10) || 0,
    message: $('nf-message').value,
    color: ['cyan', 'amber', 'violet', 'lime'][Math.floor(Math.random() * 4)],
  });
});

setInterval(renderAll, 1000);   // keeps ages ticking; a no-op when nothing changed
route();
renderAll();
EOF_FILE

echo '   operator/static/index.html'
cat > 'operator/static/index.html' <<'EOF_FILE'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>PodDisplay · cluster console</title>
<link rel="stylesheet" href="/static/styles.css" />
</head>
<body>

<header class="top">
  <div class="masthead">
    <div>
      <div class="kicker">demo.example.com / v1alpha1 / poddisplays</div>
      <h1>Pod<span>Display</span> console</h1>
      <div class="link" style="margin-top:8px">
        <i class="dot" id="dot"></i><span id="conn">connecting to the operator…</span>
      </div>
    </div>
    <div class="toolbar">
      <label><input type="checkbox" id="only-managed" checked /> only objects from a PodDisplay</label>
      <input type="search" id="filter" placeholder="filter by name or namespace" />
    </div>
  </div>

  <nav class="tabs" id="tabs">
    <a href="#/overview"     data-page="overview">Overview</a>
    <a href="#/deployments"  data-page="deployments">Deployments <b id="tab-deployments">0</b></a>
    <a href="#/replicasets"  data-page="replicasets">ReplicaSets <b id="tab-replicasets">0</b></a>
    <a href="#/pods"         data-page="pods">Pods <b id="tab-pods">0</b></a>
  </nav>
</header>

<main>
  <!-- ---------------------------------------------------------------- -->
  <section class="page" id="page-overview" hidden>
    <h2 class="section">what the cluster is running</h2>
    <div class="tiles">
      <div class="tile accent">
        <small>poddisplays</small><b id="ov-crs">0</b>
        <div class="sub" id="ov-crs-sub">custom resources</div>
      </div>
      <div class="tile">
        <small>deployments</small><b id="ov-deps">0</b>
        <div class="sub" id="ov-deps-sub">—</div>
      </div>
      <div class="tile">
        <small>replicasets</small><b id="ov-rs">0</b>
        <div class="sub" id="ov-rs-sub">—</div>
      </div>
      <div class="tile">
        <small>pods</small><b id="ov-pods">0</b>
        <div class="sub" id="ov-pods-sub">—</div>
      </div>
      <div class="tile">
        <small>replicas</small><b id="ov-replicas">0/0</b>
        <div class="sub">ready / desired across deployments</div>
      </div>
    </div>

    <h2 class="section">rollouts in flight</h2>
    <div class="stack" id="ov-rollouts"></div>

    <h2 class="section">cluster events</h2>
    <div class="log" id="log"></div>
  </section>

  <!-- ---------------------------------------------------------------- -->
  <section class="page" id="page-deployments" hidden>
    <h2 class="section">create a poddisplay</h2>
    <form class="new" id="new-form" onsubmit="return false">
      <input type="text" id="nf-name" placeholder="name" value="demo-app" />
      <input type="text" id="nf-image" placeholder="image" value="busybox:1.36" />
      <input type="number" id="nf-replicas" class="replicas" value="3" min="0" max="20" />
      <input type="text" id="nf-message" placeholder="message shown on the card" value="created from the console" />
      <button class="primary" id="nf-create">Create PodDisplay</button>
      <span class="hint">the operator turns this into a deployment</span>
    </form>

    <h2 class="section">deployments · replica count, image, rollout</h2>
    <div class="grid" id="dep-grid"></div>
    <div class="empty" id="dep-empty" hidden>
      No deployments match. Create one above, or run
      <code>./scripts/new-pod.sh my-app</code>, or untick the filter to see
      every deployment in the cluster.
    </div>
  </section>

  <!-- ---------------------------------------------------------------- -->
  <section class="page" id="page-replicasets" hidden>
    <h2 class="section">replicasets grouped by deployment · one per revision</h2>
    <div class="stack" id="rs-groups"></div>
    <div class="empty" id="rs-empty" hidden>
      No replicasets match. Each rollout leaves the old replicaset behind at zero
      replicas — that is the history <code>kubectl rollout undo</code> uses.
    </div>
  </section>

  <!-- ---------------------------------------------------------------- -->
  <section class="page" id="page-pods" hidden>
    <h2 class="section">pods</h2>
    <div class="grid" id="pod-grid"></div>
    <div class="empty" id="pod-empty" hidden>
      No pods match yet. They appear here the moment the API server accepts them.
    </div>
  </section>
</main>

<div id="toasts"></div>
<script src="/static/app.js"></script>
</body>
</html>
EOF_FILE

echo '   operator/static/styles.css'
cat > 'operator/static/styles.css' <<'EOF_FILE'
:root {
  --ink:      #0d1220;
  --ink-2:    #131b2e;
  --ink-3:    #182338;
  --text:     #eef2fb;
  --muted:    #8d9cbb;
  --rule:     #24304d;
  --cyan:     #35d6e6;
  --amber:    #ffb545;
  --violet:   #9d7bff;
  --lime:     #a3e635;
  --red:      #ff6b81;
}
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; }
body {
  background:
    repeating-linear-gradient(0deg, rgba(255,255,255,.022) 0 1px, transparent 1px 28px),
    repeating-linear-gradient(90deg, rgba(255,255,255,.022) 0 1px, transparent 1px 28px),
    radial-gradient(900px 520px at 12% -12%, #1b2748, var(--ink));
  background-attachment: fixed;
  color: var(--text);
  font-family: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
  -webkit-font-smoothing: antialiased;
}

/* ---------- header ---------- */
header.top {
  padding: 22px 28px 0; border-bottom: 1px solid var(--rule);
}
.masthead { display: flex; flex-wrap: wrap; gap: 16px 26px; align-items: flex-end; }
h1 { margin: 0; font-size: 24px; font-weight: 600; letter-spacing: -.4px; }
h1 span { color: var(--cyan); }
.kicker {
  font-size: 11px; letter-spacing: .22em; text-transform: uppercase;
  color: var(--muted); margin-bottom: 6px;
}
.link { display: inline-flex; align-items: center; gap: 8px; font-size: 12px; color: var(--muted); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--red); }
.dot.live { background: var(--cyan); box-shadow: 0 0 0 0 rgba(53,214,230,.6); animation: ping 2s infinite; }
@keyframes ping {
  70%  { box-shadow: 0 0 0 9px rgba(53,214,230,0); }
  100% { box-shadow: 0 0 0 0 rgba(53,214,230,0); }
}
.toolbar { margin-left: auto; display: flex; gap: 12px; align-items: center; font-size: 12px; color: var(--muted); }
.toolbar label { display: inline-flex; align-items: center; gap: 7px; cursor: pointer; }
.toolbar input[type=checkbox] { accent-color: var(--cyan); }
input[type=search], input[type=text], input[type=number] {
  background: var(--ink-2); border: 1px solid var(--rule); color: var(--text);
  padding: 7px 10px; border-radius: 4px; font: inherit; font-size: 12px;
}
input:focus-visible, button:focus-visible, a:focus-visible {
  outline: 2px solid var(--cyan); outline-offset: 2px;
}

/* ---------- tabs ---------- */
nav.tabs { display: flex; gap: 4px; margin-top: 18px; }
nav.tabs a {
  padding: 10px 16px; font-size: 13px; color: var(--muted); text-decoration: none;
  border: 1px solid transparent; border-bottom: none; border-radius: 5px 5px 0 0;
  display: inline-flex; align-items: center; gap: 8px;
}
nav.tabs a:hover { color: var(--text); }
nav.tabs a.active {
  color: var(--text); background: var(--ink-2);
  border-color: var(--rule); margin-bottom: -1px; padding-bottom: 11px;
}
nav.tabs b {
  font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: 99px;
  background: rgba(255,255,255,.07); color: var(--cyan);
}

/* ---------- layout ---------- */
main { padding: 24px 28px 70px; }
.page[hidden] { display: none; }
.grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); }
.stack { display: flex; flex-direction: column; gap: 14px; }
h2.section {
  font-size: 12px; letter-spacing: .18em; text-transform: uppercase;
  color: var(--muted); font-weight: 500; margin: 26px 0 12px;
}
h2.section:first-child { margin-top: 0; }

/* ---------- stat tiles ---------- */
.tiles { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
.tile { background: var(--ink-2); border: 1px solid var(--rule); border-radius: 4px; padding: 16px 18px; }
.tile b { display: block; font-size: 34px; font-weight: 600; line-height: 1.05; letter-spacing: -1px; }
.tile small { font-size: 10px; letter-spacing: .16em; text-transform: uppercase; color: var(--muted); }
.tile .sub { margin-top: 8px; font-size: 11.5px; color: var(--muted); }
.tile.accent b { color: var(--cyan); }

/* ---------- cards ---------- */
.card {
  position: relative; background: var(--ink-2); border: 1px solid var(--rule);
  border-left: 4px solid var(--accent, var(--cyan)); border-radius: 3px; padding: 15px 16px 13px;
  transition: box-shadow .25s ease, opacity .25s ease;
}
.card.enter { animation: tear .38s cubic-bezier(.22,1,.36,1) both; }
@keyframes tear {
  from { opacity: 0; transform: translateY(-9px) rotate(-.5deg); }
  to   { opacity: 1; transform: none; }
}
.card.fresh { box-shadow: 0 0 0 1px var(--accent), 0 10px 30px -14px var(--accent); }
.card.fresh::after {
  content: "new"; position: absolute; top: -8px; right: 10px;
  background: var(--accent); color: #0b1020; font-size: 9px; font-weight: 700;
  letter-spacing: .14em; text-transform: uppercase; padding: 2px 7px; border-radius: 99px;
}
.card.going { opacity: .45; filter: grayscale(.6); }
.card .ns { font-size: 10px; letter-spacing: .16em; text-transform: uppercase; color: var(--muted); }
.card .name { font-size: 15px; font-weight: 600; margin: 3px 0 10px; word-break: break-all; }
.card header { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.row {
  display: flex; justify-content: space-between; gap: 12px;
  padding: 4px 0; font-size: 12px; border-top: 1px dashed rgba(255,255,255,.07);
}
.row span:first-child { color: var(--muted); }
.row span:last-child { text-align: right; word-break: break-all; }
.badge {
  display: inline-block; padding: 2px 9px; border-radius: 99px; font-size: 11px;
  background: rgba(255,255,255,.07); color: var(--accent); white-space: nowrap;
}
.msg {
  margin-top: 10px; padding: 8px 10px; border-radius: 3px; font-size: 11.5px;
  background: rgba(255,255,255,.04); color: var(--muted); border-left: 2px solid var(--accent);
}

/* ---------- signature: the replica strip ---------- */
.pips { display: flex; flex-wrap: wrap; gap: 4px; margin: 12px 0 10px; min-height: 18px; }
.pip {
  width: 12px; height: 18px; border-radius: 2px; border: 1px solid var(--rule);
  background: rgba(255,255,255,.05); transition: background .3s ease, opacity .3s ease;
}
.pip.ready { background: var(--accent); border-color: transparent; }
.pip.starting {
  border-color: var(--amber);
  background: repeating-linear-gradient(45deg, rgba(255,181,69,.75) 0 3px, transparent 3px 6px);
}
.pip.surplus { border-style: dashed; opacity: .55; }
.legend { font-size: 11px; color: var(--muted); display: flex; gap: 14px; flex-wrap: wrap; }

/* ---------- controls ---------- */
.controls { margin-top: 12px; border-top: 1px solid var(--rule); padding-top: 12px; display: grid; gap: 8px; }
.ctl-row { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.ctl-row > label {
  font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: var(--muted);
  width: 100%; margin-bottom: 2px;
}
button {
  background: var(--ink-3, #182338); border: 1px solid var(--rule); color: var(--text);
  font: inherit; font-size: 12px; padding: 7px 11px; border-radius: 4px; cursor: pointer;
  transition: border-color .15s ease, background .15s ease;
}
button:hover { border-color: var(--cyan); }
button:disabled { opacity: .45; cursor: not-allowed; }
button.primary { background: rgba(53,214,230,.14); border-color: rgba(53,214,230,.5); color: var(--cyan); }
button.warn { border-color: rgba(255,181,69,.45); color: var(--amber); }
button.danger { border-color: rgba(255,107,129,.45); color: var(--red); }
button.step { width: 32px; padding: 7px 0; text-align: center; }
input.replicas { width: 62px; text-align: center; }
input.image { flex: 1 1 190px; min-width: 140px; }
.hint { font-size: 11px; color: var(--muted); }

/* ---------- replicaset groups ---------- */
.group { border: 1px solid var(--rule); border-radius: 4px; background: rgba(19,27,46,.6); }
.group > h3 {
  margin: 0; padding: 11px 15px; font-size: 13px; font-weight: 600;
  border-bottom: 1px solid var(--rule); display: flex; gap: 10px; align-items: center;
}
.group > h3 small { color: var(--muted); font-weight: 400; font-size: 11px; }
.rs {
  display: grid; gap: 10px; align-items: center; padding: 10px 15px; font-size: 12px;
  grid-template-columns: 62px minmax(120px, 1.6fr) 92px 1fr 92px;
  border-top: 1px dashed rgba(255,255,255,.07);
}
.rs:first-of-type { border-top: none; }
.rs .rev { color: var(--cyan); }
.rs .rs-name { word-break: break-all; color: var(--muted); }
.rs.history { opacity: .55; }
.rs .tag {
  font-size: 10px; letter-spacing: .12em; text-transform: uppercase;
  color: var(--muted); text-align: right;
}
.rs.current .tag { color: var(--lime); }

/* ---------- misc ---------- */
.empty {
  border: 1px dashed var(--rule); border-radius: 6px; padding: 34px 26px;
  color: var(--muted); font-size: 13px; line-height: 1.9;
}
.empty code { color: var(--cyan); background: rgba(53,214,230,.08); padding: 2px 6px; border-radius: 3px; }
.log {
  margin-top: 30px; border-top: 1px solid var(--rule); padding-top: 12px;
  font-size: 11.5px; color: var(--muted); max-height: 220px; overflow: auto;
}
.log div { padding: 2px 0; white-space: pre; }
.log .t { color: #5f708f; margin-right: 10px; }
.log .ADDED { color: var(--lime); }
.log .MODIFIED { color: var(--amber); }
.log .DELETED { color: var(--red); }

#toasts {
  position: fixed; right: 18px; bottom: 18px; display: flex; flex-direction: column;
  gap: 8px; z-index: 20; max-width: min(420px, 90vw);
}
.toast {
  background: var(--ink-2); border: 1px solid var(--rule); border-left: 3px solid var(--cyan);
  border-radius: 4px; padding: 10px 13px; font-size: 12px; box-shadow: 0 14px 40px -18px #000;
  animation: rise .25s ease both;
}
.toast.error { border-left-color: var(--red); }
@keyframes rise { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }

form.new {
  display: flex; gap: 8px; flex-wrap: wrap; align-items: center;
  background: var(--ink-2); border: 1px solid var(--rule); border-radius: 4px; padding: 12px 14px;
}
form.new input[type=text] { flex: 1 1 150px; }

@media (max-width: 720px) {
  header.top, main { padding-left: 16px; padding-right: 16px; }
  .rs { grid-template-columns: 52px 1fr; }
  .rs .rs-images, .rs .tag { display: none; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
EOF_FILE

echo '   operator/web.py'
cat > 'operator/web.py' <<'EOF_FILE'
"""FastAPI app: serves the dashboard, streams cluster state, runs actions."""

import asyncio
import json
import pathlib

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import actions
from broker import broker

STATIC_DIR = pathlib.Path(__file__).parent / "static"

app = FastAPI(title="PodDisplay dashboard")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class ScaleRequest(BaseModel):
    replicas: int = Field(ge=0, le=50)


class ImageRequest(BaseModel):
    container: str = "display"
    image: str


class PauseRequest(BaseModel):
    paused: bool


class PodDisplayRequest(BaseModel):
    name: str
    namespace: str = "crd-demo"
    image: str = "busybox:1.36"
    replicas: int = Field(default=1, ge=0, le=20)
    message: str = "hello from the dashboard"
    color: str = "cyan"


async def run(coro):
    try:
        message = await coro
    except actions.ActionError as exc:
        await broker.notify("error", str(exc))
        raise HTTPException(status_code=400, detail=str(exc))
    await broker.notify("ok", message)
    return {"ok": True, "message": message}


# ---- pages and state ------------------------------------------------------
@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/healthz")
async def healthz():
    return {"ok": True, "counts": broker.counts(), "viewers": broker.viewers}


@app.get("/api/state")
async def state():
    return broker.snapshot()


@app.get("/api/events")
async def events():
    async def stream():
        queue = broker.subscribe()
        try:
            yield f"event: snapshot\ndata: {json.dumps(broker.snapshot())}\n\n"
            while True:
                try:
                    message = await asyncio.wait_for(queue.get(), timeout=15)
                    name = "notice" if message.get("kind") == "notice" else "change"
                    yield f"event: {name}\ndata: {json.dumps(message)}\n\n"
                except asyncio.TimeoutError:
                    yield ": keep-alive\n\n"
        finally:
            broker.unsubscribe(queue)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ---- actions --------------------------------------------------------------
@app.post("/api/deployments/{namespace}/{name}/scale")
async def scale(namespace: str, name: str, body: ScaleRequest):
    return await run(actions.scale(namespace, name, body.replicas))


@app.post("/api/deployments/{namespace}/{name}/image")
async def image(namespace: str, name: str, body: ImageRequest):
    return await run(actions.set_image(namespace, name, body.container, body.image))


@app.post("/api/deployments/{namespace}/{name}/restart")
async def restart(namespace: str, name: str):
    return await run(actions.restart(namespace, name))


@app.post("/api/deployments/{namespace}/{name}/pause")
async def pause(namespace: str, name: str, body: PauseRequest):
    return await run(actions.pause(namespace, name, body.paused))


@app.post("/api/deployments/{namespace}/{name}/undo")
async def undo(namespace: str, name: str):
    return await run(actions.undo(namespace, name))


@app.post("/api/poddisplays")
async def create_poddisplay(body: PodDisplayRequest):
    return await run(
        actions.create_poddisplay(
            body.namespace, body.name, body.image, body.replicas,
            body.message, body.color,
        )
    )


@app.delete("/api/poddisplays/{namespace}/{name}")
async def delete_poddisplay(namespace: str, name: str):
    return await run(actions.delete_poddisplay(namespace, name))
EOF_FILE

echo '   scripts/burst.sh'
cat > 'scripts/burst.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Creates several PodDisplays a few seconds apart - good for a live demo.
set -euo pipefail
cd "$(dirname "$0")"
COUNT="${1:-4}"
for i in $(seq 1 "$COUNT"); do
  ./new-pod.sh "burst-$i-$(date +%s)" "$((RANDOM % 4 + 1))" "busybox:1.36" "app number $i"
  sleep 3
done
EOF_FILE

echo '   scripts/cleanup.sh'
cat > 'scripts/cleanup.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Removes every demo object. Deployments and pods go via owner references.
set -euo pipefail
kubectl delete poddisplays --all -n crd-demo --ignore-not-found
kubectl delete namespace crd-demo --ignore-not-found
kubectl delete -f "$(dirname "$0")/../manifests/crd.yaml" --ignore-not-found
echo ">> cleaned up"
EOF_FILE

echo '   scripts/new-pod.sh'
cat > 'scripts/new-pod.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Creates one PodDisplay -> deployment -> replicaset -> pods.
#   ./scripts/new-pod.sh [name] [replicas] [image] [message]
set -euo pipefail

NAME="${1:-demo-$(date +%s)}"
REPLICAS="${2:-3}"
IMAGE="${3:-busybox:1.36}"
MESSAGE="${4:-hello from $NAME}"
COLORS=(cyan amber violet lime)
COLOR="${COLORS[$RANDOM % ${#COLORS[@]}]}"

kubectl apply -f - <<YAML
apiVersion: demo.example.com/v1alpha1
kind: PodDisplay
metadata:
  name: ${NAME}
  namespace: crd-demo
spec:
  image: ${IMAGE}
  replicas: ${REPLICAS}
  message: "${MESSAGE}"
  color: ${COLOR}
YAML

echo ">> created poddisplay/${NAME} with ${REPLICAS} replicas - check http://localhost:8080"
EOF_FILE

echo '   scripts/rollout.sh'
cat > 'scripts/rollout.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Rollout controls straight from kubectl, mirrored live in the console.
#   ./scripts/rollout.sh restart|status|history|undo|pause|resume <deployment>
set -euo pipefail
ACTION="${1:?usage: rollout.sh restart|status|history|undo|pause|resume <deployment>}"
NAME="${2:?usage: rollout.sh <action> <deployment>}"
NS=crd-demo
case "$ACTION" in
  restart) kubectl rollout restart  deployment/"$NAME" -n "$NS" ;;
  status)  kubectl rollout status   deployment/"$NAME" -n "$NS" ;;
  history) kubectl rollout history  deployment/"$NAME" -n "$NS" ;;
  undo)    kubectl rollout undo     deployment/"$NAME" -n "$NS" ;;
  pause)   kubectl rollout pause    deployment/"$NAME" -n "$NS" ;;
  resume)  kubectl rollout resume   deployment/"$NAME" -n "$NS" ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac
EOF_FILE

echo '   scripts/run-local.sh'
cat > 'scripts/run-local.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Installs python deps, registers the CRD, and runs the operator + console.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null || { echo "no reachable cluster - start kind/minikube first"; exit 1; }

if [ ! -d .venv ]; then
  echo ">> creating virtualenv"
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r operator/requirements.txt

echo ">> registering the CRD"
kubectl apply -f manifests/crd.yaml
kubectl wait --for=condition=Established crd/poddisplays.demo.example.com --timeout=60s

echo ">> ensuring namespace crd-demo"
kubectl create namespace crd-demo --dry-run=client -o yaml | kubectl apply -f -

export PORT="${PORT:-8080}"
cd operator
exec python main.py
EOF_FILE

echo '   scripts/scale.sh'
cat > 'scripts/scale.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Change the replica count on a PodDisplay: ./scripts/scale.sh hello-world 5
set -euo pipefail
NAME="${1:?usage: scale.sh <poddisplay> <replicas>}"
REPLICAS="${2:?usage: scale.sh <poddisplay> <replicas>}"
kubectl patch poddisplay "$NAME" -n crd-demo --type=merge \
  -p "{\"spec\":{\"replicas\":${REPLICAS}}}"
echo ">> ${NAME} now wants ${REPLICAS} replicas"
EOF_FILE

echo '   scripts/set-image.sh'
cat > 'scripts/set-image.sh' <<'EOF_FILE'
#!/usr/bin/env bash
# Roll out a new image: ./scripts/set-image.sh hello-world busybox:1.37
set -euo pipefail
NAME="${1:?usage: set-image.sh <poddisplay> <image>}"
IMAGE="${2:?usage: set-image.sh <poddisplay> <image>}"
kubectl patch poddisplay "$NAME" -n crd-demo --type=merge \
  -p "{\"spec\":{\"image\":\"${IMAGE}\"}}"
echo ">> ${NAME} rolling out ${IMAGE}"
kubectl rollout status deployment/"$NAME" -n crd-demo --timeout=120s || true
EOF_FILE

chmod +x scripts/*.sh

echo ""
echo "   done. project created in ./$PROJECT"
echo ""
echo "   next:"
echo "     cd $PROJECT"
echo "     ./scripts/run-local.sh          # installs deps, applies the CRD, starts the console"
echo "     open http://localhost:8080"
echo "     ./scripts/new-pod.sh my-app 4   # in another terminal"
echo ""
