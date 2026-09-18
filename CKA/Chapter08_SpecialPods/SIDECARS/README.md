# Kubernetes Sidecar Pattern — Hall Ticket Generator Demo

A hands-on demo of the **sidecar pattern**: two containers in one pod, working together
through a **shared volume**. A Flask **frontend** takes exam details from a web form and a
**sidecar** renders them into a polished PDF admit card — neither container does the other's
job, and they never talk over the network.

```
Browser ──HTTP──▶  frontend (Flask :8080)
                        │  writes /shared/request.txt
                        ▼
                   [ emptyDir volume mounted at /shared in BOTH containers ]
                        ▲
                        │  writes /shared/hallticket.pdf
                   pdf-sidecar (watches the folder, renders PDF with reportlab)
```

---

## What this demo teaches

### The sidecar pattern
A **sidecar** is a helper container that runs **alongside** your main app container in the
**same pod**, extending or supporting it without being baked into the main image. Because
containers in a pod share the pod's **network** and can share **volumes**, the sidecar can
cooperate closely with the main app.

Here the split is deliberate:

| Container      | Job                                             | Why it's separate |
|----------------|-------------------------------------------------|-------------------|
| `frontend`     | Serve the web form, accept input, return the PDF | It's a web app; it shouldn't need PDF libraries. |
| `pdf-sidecar`  | Watch for a request and render the PDF           | Heavy `reportlab` logic stays out of the frontend image. |

This is the real value of the pattern: **separation of concerns**. You can rebuild, update,
or swap the PDF renderer without touching the frontend, and vice versa.

### How the two containers communicate — a shared volume
They do **not** use HTTP between each other. Instead, both mount the **same `emptyDir`
volume** at `/shared`, and pass work through files:

1. User submits the form → frontend writes `/shared/request.txt` (`name|batch|course`).
2. The sidecar loops every 2s, sees `request.txt`, and renders `/shared/hallticket.pdf`.
3. The frontend polls for `/shared/hallticket.pdf` (up to 30s) and streams it back as a
   download.

> **`emptyDir`** is a pod-scoped scratch volume: created when the pod starts, shared by all
> its containers, and **deleted when the pod dies**. It's the classic way sidecars and main
> containers exchange files. (Filesystem hand-off like this is one common style; log shippers
> and proxies are other typical sidecar jobs.)

### Loading local images into a cluster
Because the images are built locally (not pushed to a registry), the demo:
- builds each image with `docker build`,
- imports them into the cluster's **containerd** namespace (`k8s.io`) with `ctr`,
- and the Deployment sets **`imagePullPolicy: Never`** so Kubernetes uses the local image
  instead of trying to pull from a registry.

---

## Files this demo generates

Running `setup_for_sidecar.sh` scaffolds the whole project:

```
frontend/
  app.py            # Flask web app: form + /generate endpoint
  requirements.txt  # flask
  Dockerfile        # python:3.11-slim, serves on :8080
sidecar/
  sidecar.py        # watches /shared, renders the PDF with reportlab
  Dockerfile        # python:3.11-slim + reportlab
k8s/
  deployment.yaml   # ONE pod, TWO containers, ONE shared emptyDir volume
  service.yaml      # NodePort service → 30080
```

The two provided files are:
- **`setup_for_sidecar.sh`** — creates all of the above.
- **`commands_for_practical.txt`** — the build + image-import commands.

---

## Prerequisites

- A Kubernetes cluster whose container runtime is **containerd** (so `ctr` works — e.g. a
  kubeadm cluster, k3s, or similar). `kubectl` configured to talk to it.
- `docker` for building images.
- Run on the **node** where the pod will be scheduled, since the local images are imported
  into that node's containerd.

> **Note on minikube / kind / Docker Desktop:** the `ctr ... import` step is for a containerd
> node. On minikube use `minikube image load hallticket-frontend:v1` instead; on kind use
> `kind load docker-image hallticket-frontend:v1`. The `imagePullPolicy: Never` line still
> applies.

---

## Steps

### 1. Scaffold the project
```bash
bash setup_for_sidecar.sh
```
Expected: it prints `PROJECT CREATED` and you now have `frontend/`, `sidecar/`, and `k8s/`.

### 2. Build both images
```bash
cd frontend
docker build -t hallticket-frontend:v1 .

cd ../sidecar
docker build -t hallticket-sidecar:v1 .
```

### 3. Export the images to tarballs
```bash
docker save hallticket-frontend:v1 -o frontend.tar
docker save hallticket-sidecar:v1  -o sidecar.tar
```

### 4. Import them into the cluster's containerd (`k8s.io` namespace)
```bash
sudo ctr -n=k8s.io images import frontend.tar
sudo ctr -n=k8s.io images import sidecar.tar

# verify both are present
sudo ctr -n=k8s.io images ls | grep hallticket
```
This is what makes `imagePullPolicy: Never` work — the images already exist on the node.

### 5. Deploy the pod and the service
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 6. Confirm the pod has BOTH containers running
```bash
kubectl get pods
```
Expected — `READY 2/2` proves the frontend and the sidecar are both up in one pod:
```
NAME                             READY   STATUS    RESTARTS   AGE
hallticket-app-xxxxxxxxx-xxxxx   2/2     Running   0          ...
```

### 7. Open the app and generate a PDF
Reach the NodePort service:
```bash
# node IP + nodePort 30080
curl http://<NodeIP>:30080          # or open it in a browser
```
Fill in the form and submit — the frontend writes the request, the sidecar renders the PDF,
and your browser downloads `admit_card.pdf`. That round trip **is** the sidecar pattern in
action.

---

## See the two containers cooperating (great for teaching)

**Logs from each container separately** — note `-c` picks the container:
```bash
POD=$(kubectl get pod -l app=hallticket -o jsonpath='{.items[0].metadata.name}')

kubectl logs $POD -c frontend      # Flask request logs
kubectl logs $POD -c pdf-sidecar   # sidecar rendering / errors
```

**Watch the shared volume from inside each container** — same files, two containers:
```bash
kubectl exec $POD -c frontend     -- ls -l /shared
kubectl exec $POD -c pdf-sidecar  -- ls -l /shared
```
Submit the form, then run these quickly and you'll catch `request.txt` appear and
`hallticket.pdf` show up — written by one container, read by the other.

**Describe the pod** to see both containers and the shared volume mount:
```bash
kubectl describe pod $POD
```

---

## Key takeaways

- A **sidecar** is a second container in the **same pod** that supports the main app —
  here, offloading PDF generation from the web frontend.
- Containers in a pod share the pod's network and can share a **volume**; this demo passes
  work through an **`emptyDir`** mounted at `/shared` in both, using files rather than a
  network call.
- **Separation of concerns:** the frontend image stays lean (just Flask); the PDF logic and
  `reportlab` live only in the sidecar.
- For locally built images, import them into the node's containerd and set
  **`imagePullPolicy: Never`** so Kubernetes doesn't try to pull from a registry.
- `emptyDir` is **ephemeral** — the shared PDF and request files vanish when the pod is
  deleted or rescheduled.

---

## Cleanup

```bash
kubectl delete -f k8s/service.yaml
kubectl delete -f k8s/deployment.yaml

# optional: remove the imported images from the node
sudo ctr -n=k8s.io images rm docker.io/library/hallticket-frontend:v1
sudo ctr -n=k8s.io images rm docker.io/library/hallticket-sidecar:v1
```
