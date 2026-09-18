# AKS Persistent Storage Demo

A hands-on demo of persistent storage on Azure Kubernetes Service (AKS), showing both ways to give a pod a persistent disk:

- **Dynamic provisioning** — Kubernetes creates the Azure managed disk for you, on demand, via a StorageClass.
- **Static provisioning** — you create the Azure managed disk yourself and wire it up manually with a PersistentVolume.

Both demos mount an Azure disk into an nginx pod at `/data` and prove the data survives a pod restart.

## Layout

```
aks-storage-demo/
├── README.md
├── scripts/
│   ├── 01-create-cluster.ps1      # Provision the AKS cluster + kubeconfig
│   ├── 02-static-disk-setup.ps1   # Create the managed disk (static demo only)
│   ├── 03-test-persistence.ps1    # Write a file, restart the pod, read it back
│   └── 99-cleanup.ps1             # Tear everything down
├── dynamic/
│   ├── dynamic-pvc.yaml           # PVC using the managed-csi StorageClass
│   └── dynamic-pod.yaml           # Pod mounting dynamic-pvc
└── static/
    ├── azure-pv.yaml              # PV pointing at your pre-created disk
    ├── azure-pvc.yaml             # PVC bound to azure-pv
    └── static-pod.yaml            # Pod mounting azure-pvc
```

## Prerequisites

- Azure CLI (`az`) and `kubectl`
- An Azure subscription with permission to create resource groups, AKS, and disks
- PowerShell (scripts use PowerShell backtick line continuation and `D:\credsaks\config` for the kubeconfig — adjust paths for macOS/Linux)

## Step 1 — Create the cluster

```powershell
./scripts/01-create-cluster.ps1
```

This logs in, creates the `aks-demo-rg` resource group and `aks-demo` cluster, writes the kubeconfig to `D:\credsaks\config`, and lists the available StorageClasses. Confirm `managed-csi` appears in the list.

## Step 2a — Dynamic provisioning

No disk to pre-create — the StorageClass does it.

```powershell
kubectl apply -f dynamic/dynamic-pvc.yaml
kubectl apply -f dynamic/dynamic-pod.yaml

kubectl get pvc dynamic-pvc      # STATUS should become Bound
kubectl get pv                   # a PV was auto-created for the claim
```

## Step 2b — Static provisioning

First create the Azure disk and copy its resource ID:

```powershell
./scripts/02-static-disk-setup.ps1
```

Paste the printed disk ID into the `volumeHandle` field of `static/azure-pv.yaml`, then:

```powershell
kubectl apply -f static/azure-pv.yaml
kubectl apply -f static/azure-pvc.yaml
kubectl apply -f static/static-pod.yaml

kubectl get pv azure-pv          # STATUS Bound to azure-pvc
kubectl get pvc azure-pvc        # STATUS Bound
```

## Step 3 — Prove persistence

```powershell
./scripts/03-test-persistence.ps1
```

It writes `AKBLAZE` to `/data/demo.txt`, deletes and recreates the pod, then reads the file back. Because the disk is decoupled from the pod, the file is still there after the restart.

## Step 4 — Clean up

```powershell
./scripts/99-cleanup.ps1
```

Note: the static PV uses `persistentVolumeReclaimPolicy: Retain`, so deleting the PVC/PV does **not** delete the underlying Azure disk. The cleanup script removes it explicitly with `az disk delete`.

## Dynamic vs static — which to use

| | Dynamic | Static |
|---|---|---|
| Who creates the disk | Kubernetes (StorageClass) | You (`az disk create`) |
| PV | Auto-created | You write it |
| Best for | Most workloads | Pre-existing disks, restoring from a snapshot, tight control |
| Reclaim policy here | Delete (default) | Retain |

## Notes & fixes applied

Two things in the original manifests were corrected so the static demo actually works:

1. **`volumeHandle` was set to a CLI command instead of a value.** It must be the disk's Azure resource ID (the output of `az disk show ... --query id -o tsv`), not the command text. There's now a placeholder and a comment pointing to the script that prints it.
2. **The static PVC had no `storageClassName`.** With no value, it falls through to the cluster's *default* StorageClass and dynamically provisions a brand-new disk instead of binding to `azure-pv`. Setting `storageClassName: ""` on both the PV and PVC (plus `volumeName: azure-pv` on the claim) forces the intended static binding.
