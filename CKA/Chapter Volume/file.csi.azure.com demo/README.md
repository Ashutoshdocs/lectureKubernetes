# Demo — Azure Blob Container as nginx Web Root (edit in Azure → see it in the pod)

An **Azure Storage account container** (blob) is mounted into an nginx pod at
`/usr/share/nginx/html` using the **Azure Blob CSI driver**. You upload
`index.html`, `image1.png`, and `image2.png` to the blob container. When you edit
`index.html` **in Azure** to reference a different image, the running pod serves the
change — no rebuild, no redeploy.

> **Why not `hostPath`?** `hostPath` is the node's local disk, which can't point at a
> storage account. Mounting an Azure blob container is done with a PV/PVC backed by
> `blob.csi.azure.com`. That's what `deployment.yaml` does.

## Files

| File | Purpose |
|------|---------|
| `deployment.yaml` | PersistentVolume + PVC (Blob CSI) + nginx Deployment |
| `service.yaml` | NodePort Service on port `30080` |
| `index.html` | Upload to the blob container (references `image1.png`) |
| `image1.png`, `image2.png` | Sample images — upload both to the blob container |
| `README.md` | This guide |

---

## Prerequisites

- An **AKS** cluster and `kubectl` pointed at it (`az aks get-credentials ...`)
- **Azure CLI** (`az`) logged in (`az login`)

Set some shell variables you'll reuse:

```bash
RG=myResourceGroup
LOCATION=eastus
AKS=myAksCluster
STORAGE=mystorage$RANDOM        # must be globally unique, lowercase
CONTAINER=web                   # the blob container name
```

## Step 1 — Enable the Blob CSI driver on AKS

```bash
az aks update -n $AKS -g $RG --enable-blob-driver

# verify the driver is present
kubectl get csidrivers | grep blob        # -> blob.csi.azure.com
```

## Step 2 — Create the storage account and a blob container

```bash
az storage account create -n $STORAGE -g $RG -l $LOCATION --sku Standard_LRS

# get a key and create the container
KEY=$(az storage account keys list -n $STORAGE -g $RG --query "[0].value" -o tsv)
az storage container create -n $CONTAINER --account-name $STORAGE --account-key "$KEY"
```

## Step 3 — Upload index.html and both images to the container

```bash
az storage blob upload-batch \
  --account-name $STORAGE --account-key "$KEY" \
  -d $CONTAINER -s .            # run from the folder containing index.html + the images

# confirm
az storage blob list --account-name $STORAGE --account-key "$KEY" \
  -c $CONTAINER -o table         # should list index.html, image1.png, image2.png
```

## Step 4 — Create the Kubernetes secret with the storage-account key

The Blob CSI driver reads the account name/key from a secret named `azure-blob-secret`:

```bash
kubectl create secret generic azure-blob-secret \
  --from-literal azurestorageaccountname=$STORAGE \
  --from-literal azurestorageaccountkey="$KEY"
```

## Step 5 — Fill in the placeholders in `deployment.yaml`

Edit `deployment.yaml` and replace:

- `<RESOURCE_GROUP>`  → your `$RG`
- `<STORAGE_ACCOUNT>` → your `$STORAGE`
- `<CONTAINER_NAME>`  → your `$CONTAINER`

(Quick sed version:)

```bash
sed -i "s/<RESOURCE_GROUP>/$RG/; s/<STORAGE_ACCOUNT>/$STORAGE/; s/<CONTAINER_NAME>/$CONTAINER/" deployment.yaml
```

## Step 6 — Deploy

```bash
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pvc                            # blob-pvc should be Bound
kubectl get pods -l app=nginx-blob         # should be Running
kubectl get svc nginx-blob-svc
```

Sanity check the mount:

```bash
POD=$(kubectl get pod -l app=nginx-blob -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -- ls /usr/share/nginx/html   # -> index.html image1.png image2.png
```

## Step 7 — Open it in a browser

AKS nodes usually have no public IP, so the simplest test is a port-forward:

```bash
# Local test (browse http://localhost:8080)
kubectl port-forward svc/nginx-blob-svc 8080:80
```

To use the real **NodePort 30080** from outside, open it on the node's NSG and hit
`http://<node-ip>:30080` (or switch the Service `type` to `LoadBalancer` for a public
IP). NodePort works cluster-internally in all cases.

You should see **IMAGE 1**.

---

## Step 8 — The demo: change the image from Azure, see it in the pod

Edit `index.html` **in the blob container** so it points at `image2.png` instead of
`image1.png`, then re-upload it:

```bash
# swap image1.png -> image2.png in the local copy, then re-upload (overwrite)
sed -i 's/image1.png/image2.png/g' index.html
az storage blob upload \
  --account-name $STORAGE --account-key "$KEY" \
  -c $CONTAINER -f index.html -n index.html --overwrite
```

(Or edit it directly in the Azure Portal → Storage account → Containers → your
container → `index.html` → Edit.)

Refresh the browser. The page now shows **IMAGE 2** — served by the same pod, from the
edited blob. Because the PV sets `--file-cache-timeout-in-seconds=0`, the change shows
up within a few seconds.

---

## Cleanup

```bash
kubectl delete -f service.yaml
kubectl delete -f deployment.yaml
kubectl delete secret azure-blob-secret
# storage (optional):
az storage container delete -n $CONTAINER --account-name $STORAGE --account-key "$KEY"
az storage account delete -n $STORAGE -g $RG -y
```

---

## Notes

- **Live updates:** `--file-cache-timeout-in-seconds=0` keeps blobfuse from caching so
  edited files appear quickly. Increase it (e.g. `120`) in production for performance.
- **Secret key names matter:** they must be exactly `azurestorageaccountname` and
  `azurestorageaccountkey` for the CSI driver.
- **ReadWriteMany:** blob mounts support RWX, so you can scale replicas and they all
  see the same files.
- **Retain policy:** `persistentVolumeReclaimPolicy: Retain` means deleting the PVC
  won't wipe your blob container.
- **image1.png / image2.png** are sample placeholders — replace them with your own,
  keeping the same names, and re-upload.
