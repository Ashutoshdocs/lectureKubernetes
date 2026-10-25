# Mounting an Azure File Share in Kubernetes (Static Provisioning) — Demo

A hands-on demo that mounts an **Azure File Share** into an **nginx** Pod using the
Azure File CSI driver, then serves a page from that share through a **NodePort**
Service.

By the end you will have:

- An Azure File Share credential stored as a Kubernetes `Secret`
- A **statically provisioned** `PersistentVolume` (PV) backed by the file share
- A `PersistentVolumeClaim` (PVC) bound to that PV
- An nginx Pod writing to and serving from the mounted share
- A NodePort Service exposing nginx on port `30080`

---

## ⚠️ Read this first — security

The file `k8s_get_secret.yml` in this repo contains a **real-looking Azure storage
account key** in plain text. **Never commit real credentials to source control.**

Before using or sharing this repo:

1. Replace `azurestorageaccountname` and `azurestorageaccountkey` with **placeholders**.
2. If the key was ever real, **rotate it** in the Azure Portal
   (Storage account → *Access keys* → *Rotate key*).
3. Consider loading the secret from an env var or a secrets manager instead of a file.

```yaml
# k8s_get_secret.yml (sanitized)
stringData:
  azurestorageaccountname: <YOUR_STORAGE_ACCOUNT_NAME>
  azurestorageaccountkey: <YOUR_STORAGE_ACCOUNT_KEY>
```

---

## Architecture

```
                       ┌─────────────────────────────┐
   curl NodeIP:30080   │        Kubernetes Node       │
  ────────────────────►│  ┌────────────────────────┐ │
                        │  │  Service (NodePort)     │ │
                        │  │  nginx-nodeport :30080  │ │
                        │  └───────────┬────────────┘ │
                        │              │ selector app=nginx
                        │  ┌───────────▼────────────┐ │
                        │  │  Pod: nginx-storage     │ │
                        │  │  mount /usr/share/      │ │
                        │  │        nginx/html       │ │
                        │  └───────────┬────────────┘ │
                        │              │ PVC: azurefile-pvc
                        │  ┌───────────▼────────────┐ │
                        │  │  PV: azurefile-pv       │ │
                        │  │  CSI file.csi.azure.com │ │
                        │  └───────────┬────────────┘ │
                        └──────────────┼──────────────┘
                                       │ Secret: azure-secret
                                       ▼
                          ┌──────────────────────────┐
                          │   Azure File Share        │
                          │   share: myfileshare      │
                          └──────────────────────────┘
```

---

## Files in this repo

| File | Kind | What it does |
|------|------|--------------|
| `k8s_get_secret.yml` | `Secret` | Holds the Azure storage account name + key the CSI driver uses to mount the share. |
| `pv.yml` | `PersistentVolume` | Statically defines a 5Gi volume backed by the Azure file share via the CSI driver. |
| `pvc.yml` | `PersistentVolumeClaim` | Requests 5Gi and binds explicitly to `azurefile-pv` (`volumeName`). |
| `pod.yml` | `Pod` | nginx container mounting the PVC at `/usr/share/nginx/html`. |
| `service.yml` | `Service` | NodePort service exposing nginx on `30080`. |
| `pv_pvc_queries.txt` | commands | Helper commands (install driver, exec, taints, etc.). |

---

## Prerequisites

- A running Kubernetes cluster with `kubectl` configured.
- An existing **Azure Storage account** and a **File Share** inside it
  (default name here is `myfileshare` — see `pv.yml` → `shareName`).
- The **Azure File CSI driver** installed (step 1 below).

---

## How the pieces connect

The binding is intentionally explicit for teaching purposes:

- `pvc.yml` uses `volumeName: azurefile-pv` → binds to a specific PV, not "any matching one".
- Both PV and PVC set `storageClassName: ""` → disables dynamic provisioning, forcing
  **static** binding.
- `pv.yml` → `nodeStageSecretRef` points at the `azure-secret` in the `default` namespace,
  so the driver knows which credentials to use when it stages the mount.
- `pod.yml` → `claimName: azurefile-pvc` connects the Pod's volume to the PVC.
- `service.yml` → `selector: app=nginx` matches the label on the Pod.

If any of these names/labels drift out of sync, binding or routing silently fails —
a great thing to demo intentionally.

---

## Step-by-step

### 1. Install the Azure File CSI driver

```bash
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/master/deploy/install-driver.sh | bash

# verify the CSI pods are running
kubectl get pods -A | grep csi
```

> Tip: piping a script from the internet straight into `bash` is fine for a demo, but in
> real environments download, read, and pin a version first.

### 2. (Single-node / lab only) Allow scheduling on the control plane

On a lab cluster where the control-plane node must also run workloads, remove the taint:

```bash
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule-
```

Skip this on multi-node or production clusters.

### 3. Create the Secret

```bash
kubectl apply -f k8s_get_secret.yml
kubectl get secret azure-secret
```

### 4. Create the PV and PVC

```bash
kubectl apply -f pv.yml
kubectl apply -f pvc.yml

# PVC should show STATUS: Bound to azurefile-pv
kubectl get pv,pvc
```

### 5. Deploy the Pod and Service

```bash
kubectl apply -f pod.yml
kubectl apply -f service.yml

kubectl get pod nginx-storage -o wide
kubectl get svc nginx-nodeport
```

### 6. Write a test page onto the share

```bash
kubectl exec -it nginx-storage -- bash
# inside the container:
echo "Hello Azure File Share" > /usr/share/nginx/html/index.html
exit
```

### 7. Access it

```bash
# get a node's IP
kubectl get nodes -o wide

# from anywhere that can reach the node:
curl http://<NODE_IP>:30080
# → Hello Azure File Share
```

---

## Verify persistence (the point of the demo)

Because the data lives on the Azure File Share, it survives the Pod:

```bash
kubectl delete pod nginx-storage
kubectl apply -f pod.yml

# the page is still there — served from the same share
curl http://<NODE_IP>:30080
```

You can also confirm the file exists directly in the Azure Portal under the file share.

---

## Useful commands (from `pv_pvc_queries.txt`)

```bash
# Install the CSI driver
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/master/deploy/install-driver.sh | bash

# Check CSI pods
kubectl get pods -A | grep csi

# Untaint control-plane (lab clusters)
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule-

# Shell into the nginx pod
kubectl exec -it nginx-storage -- bash

# Write the demo page
echo "Hello Azure File Share" > /usr/share/nginx/html/index.html

# Drain-lite: stop scheduling new pods onto a node
kubectl cordon worker
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| PVC stuck in `Pending` | `volumeName`/`storageClassName` mismatch between PV and PVC | Ensure both use `storageClassName: ""` and the PVC's `volumeName` matches the PV name. |
| Pod stuck in `ContainerCreating` | Mount failing — wrong credentials or share name | `kubectl describe pod nginx-storage`; check `azure-secret` values and `shareName` in `pv.yml`. |
| `MountVolume.SetUp failed` | CSI driver not installed / not ready | `kubectl get pods -A \| grep csi` and re-run the install step. |
| 404 or empty page on `curl` | No `index.html` on the share yet | Re-run step 6. |
| Can't reach `:30080` | Node firewall / NSG blocking the NodePort | Open the NodePort range (30000–32767) to your client. |

Handy inspection commands:

```bash
kubectl describe pv azurefile-pv
kubectl describe pvc azurefile-pvc
kubectl describe pod nginx-storage
kubectl logs nginx-storage
```

---

## Cleanup

```bash
kubectl delete -f service.yml
kubectl delete -f pod.yml
kubectl delete -f pvc.yml
kubectl delete -f pv.yml
kubectl delete -f k8s_get_secret.yml
```

Note: the PV uses `persistentVolumeReclaimPolicy: Retain`, so the **data on the Azure
File Share is not deleted** when you remove the PV. Delete the share in Azure manually
if you want it gone.

---

## Key concepts recap (for the class)

- **CSI driver** — the plugin that lets Kubernetes talk to external storage (here, Azure Files).
- **Static provisioning** — you create the PV by hand and point it at existing storage,
  versus **dynamic provisioning** where a StorageClass creates volumes on demand.
- **PV vs PVC** — the PV is the actual storage resource; the PVC is a request/claim for it.
  The Pod only ever references the PVC.
- **`Retain` reclaim policy** — protects data from accidental deletion when the PV goes away.
- **NodePort** — exposes a Service on a static port on every node, the simplest way to reach
  a workload from outside a lab cluster.
