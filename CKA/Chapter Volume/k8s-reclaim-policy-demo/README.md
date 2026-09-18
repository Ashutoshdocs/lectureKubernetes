# Kubernetes PV Reclaim Policy — Proven with Steps

`Retain` vs `Delete`, shown end to end: what happens to the **PV** and the
**actual data** when you delete a **PVC**.

> **The reclaim policy answers one question:** when a PVC is deleted, what
> happens to the PV bound to it and the storage behind it?
>
> | Policy | On PVC delete | PV becomes | Data | Default for |
> |--------|---------------|-----------|------|-------------|
> | **Retain** | PV kept, unbound | `Released` (needs manual cleanup) | **kept** | statically-created PVs |
> | **Delete** | PV deleted + backend volume deleted | *gone* | **gone** | dynamically-provisioned PVs |
> | ~~Recycle~~ | deprecated — don't use | — | — | — |

---

## Files

```
k8s-reclaim-policy-demo/
├── README.md
├── 10-retain/retain-pv-pvc-pod.yaml   # Retain: namespace + PV + PVC + writer pod
├── 20-delete/delete-pvc-pod.yaml      # Delete: dynamic PVC (default SC) + writer pod
└── 30-recover/recover-pvc.yaml        # reuse a Retained PV after clearing claimRef
```

## Prerequisites

- A cluster + `kubectl`. A single-node kind/minikube/Docker-Desktop is fine.
- The `Delete` part needs a **default StorageClass** with `reclaimPolicy: Delete`
  (kind, minikube, EKS/GKE/AKS all ship one). Check:

  ```bash
  kubectl get sc -o custom-columns=\
NAME:.metadata.name,RECLAIM:.reclaimPolicy,PROVISIONER:.provisioner,\
DEFAULT:.metadata.annotations.'storageclass\.kubernetes\.io/is-default-class'
  ```

---

## Part A — `Retain`: deleting the PVC keeps the PV and the data

### 1. Create PV + PVC + a pod that writes data
```bash
kubectl apply -f 10-retain/retain-pv-pvc-pod.yaml
kubectl -n reclaim-demo wait --for=condition=Ready pod/retain-writer --timeout=60s
```

### 2. Confirm the reclaim policy and that data was written
```bash
kubectl get pv retain-pv -o custom-columns=NAME:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase
kubectl -n reclaim-demo exec retain-writer -- cat /data/precious.txt
```
Expect `POLICY: Retain`, `STATUS: Bound`, and a line of "important data...".

### 3. Delete the pod, then the PVC (simulate losing the workload)
```bash
kubectl -n reclaim-demo delete pod retain-writer
kubectl -n reclaim-demo delete pvc retain-pvc
```

### 4. ✅ PROOF: the PV is still there, now `Released`
```bash
kubectl get pv retain-pv
```
```
NAME        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     ...
retain-pv   100Mi      RWO            Retain           Released   ...
```
The PVC is gone but the **PV survived** and was **not** recycled. Data is intact
on disk (`/mnt/data/retain-pv/precious.txt` on the node). Nothing auto-deleted it.

### 5. (Optional) See the leftover binding that blocks re-use
```bash
kubectl get pv retain-pv -o jsonpath='{.spec.claimRef.name}{"\n"}'   # -> retain-pvc
```
A `Released` PV keeps `claimRef` pointing at the deleted PVC, so it won't bind to
anything new until an admin clears it. That's the manual step Retain requires.

### 6. Recover the data with a new claim
```bash
# clear the stale binding so the PV becomes Available again
kubectl patch pv retain-pv --type merge -p '{"spec":{"claimRef": null}}'
kubectl get pv retain-pv        # STATUS should now be Available

# a fresh PVC + pod bind to the same PV and read the old data
kubectl apply -f 30-recover/recover-pvc.yaml
kubectl -n reclaim-demo wait --for=condition=Ready pod/retain-reader --timeout=60s
kubectl -n reclaim-demo exec retain-reader -- cat /data/precious.txt
```
✅ You see the **same** "important data..." line written back in step 1 — it
survived PVC deletion and was recovered. That is the whole point of `Retain`.

---

## Part B — `Delete`: deleting the PVC destroys the PV and the data

### 1. Create a dynamic PVC (uses the default SC) + a writer pod
```bash
kubectl apply -f 20-delete/delete-pvc-pod.yaml
kubectl -n reclaim-demo wait --for=condition=Ready pod/delete-writer --timeout=90s
```

### 2. Note the auto-provisioned PV name and its policy
```bash
kubectl -n reclaim-demo get pvc delete-pvc          # note the VOLUME (pvc-xxxx)
PV=$(kubectl -n reclaim-demo get pvc delete-pvc -o jsonpath='{.spec.volumeName}')
echo "provisioned PV = $PV"
kubectl get pv "$PV" -o custom-columns=NAME:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase
```
Expect `POLICY: Delete`, `STATUS: Bound`. You never wrote a PV — the SC made one.

### 3. Delete the pod, then the PVC
```bash
kubectl -n reclaim-demo delete pod delete-writer
kubectl -n reclaim-demo delete pvc delete-pvc
```

### 4. ✅ PROOF: the PV disappears on its own
```bash
kubectl get pv "$PV"
```
```
Error from server (NotFound): persistentvolumes "pvc-xxxx" not found
```
Deleting the PVC triggered the provisioner to delete the PV **and** the backing
volume in the storage system. No manual cleanup, but the **data is unrecoverable**.

---

## Bonus — flip a live PV's policy

You can change an existing PV's policy in place (common fix: protect a
dynamically-provisioned volume by switching it to `Retain` before deleting its
PVC):

```bash
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Do this **before** deleting the PVC and the volume will survive.

---

## What to remember

- **Reclaim policy is a property of the PV**, evaluated at PVC-delete time.
- **Retain = safe but manual.** PV goes `Released`; you must clear `claimRef`
  (or recreate the PV) to reuse it. Nothing is deleted for you.
- **Delete = convenient but destructive.** PV and backend volume vanish with the
  PVC. This is the default for dynamic provisioning — know it before you `kubectl
  delete pvc` in production.
- **Recycle is deprecated** — ignore it; use dynamic provisioning instead.

## Cleanup

```bash
# Part A leftovers
kubectl -n reclaim-demo delete pod retain-reader --ignore-not-found
kubectl -n reclaim-demo delete pvc retain-pvc-v2 --ignore-not-found
kubectl delete pv retain-pv --ignore-not-found
# namespace + anything else
kubectl delete namespace reclaim-demo --ignore-not-found
```
