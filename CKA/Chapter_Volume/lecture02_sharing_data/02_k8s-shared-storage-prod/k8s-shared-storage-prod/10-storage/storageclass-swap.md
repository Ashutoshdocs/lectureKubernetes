# Going fully managed: swap the NFS server for a cloud RWX StorageClass

The workloads never change — only the storage layer. Delete
`nfs-server.yaml` + the `PersistentVolume` in `shared-pv-pvc.yaml`, and give the
**PVC** a `storageClassName`. Keep `accessModes: [ReadWriteMany]`.

| Platform | RWX StorageClass / provisioner | Notes |
|----------|-------------------------------|-------|
| AWS EKS | `efs-sc` (efs.csi.aws.com) | provision an EFS filesystem + access points |
| Azure AKS | `azurefile-csi` (file.csi.azure.com) | SMB/NFS Azure Files share |
| GCP GKE | `standard-rwx` / Filestore (filestore.csi.storage.gke.io) | managed NFS |
| On-prem | Ceph `cephfs` (cephfs.csi.ceph.com), or NFS-subdir provisioner | |

Example managed PVC (EKS/EFS):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-pvc
  namespace: shared-storage
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc          # <-- the only line that differs per cloud
  resources:
    requests:
      storage: 5Gi
```

Everything in `20-workloads/` binds to `shared-pvc` by name and is unaffected —
that's the payoff of decoupling workloads from storage via a PVC.
