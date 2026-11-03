# Chapter15Cluster — kubeadm Cluster Upgrade + etcd Backup/Restore Demo

End-to-end practical on a **2-node kubeadm cluster** (1 master + 1 worker):

```text
 Setup cluster on OLD version (v1.34)
        │
        ▼
 Take etcd backup  ──────────────► /opt/etcd-backup/etcd-snapshot-before-upgrade.db
        │
        ▼
 Create 3 new deployments (upgrade-demo namespace)
        │
        ▼
 Upgrade ALL components to NEW version (v1.35)
   master: kubeadm → apiserver/controller-manager/scheduler/etcd/kube-proxy/CoreDNS → kubelet/kubectl
   worker: kubeadm → kubeadm upgrade node → kubelet/kubectl
        │
        ▼
 Restore the etcd backup on the upgraded cluster
   → the 3 deployments disappear (proof the restore worked), nodes stay on v1.35
```

> Based on `Chapter00_clustersetup/mutlinodeCluster` (copied to `original_setup_reference/`).
> Same flow: containerd + Calico with Azure-safe VXLAN IPPool.

---

## Files

| File | Where | What |
|---|---|---|
| `ScriptForBothNode.sh` | master + worker | swap off, kernel modules, containerd, kubeadm/kubelet/kubectl **OLD version** |
| `ScriptFormaster.sh` | master | `kubeadm init`, kubeconfig, Calico, writes **`worker_join.sh` in the same folder** |
| `01-etcd-backup.sh` | master | installs matching etcdctl/etcdutl, takes snapshot |
| `02-demo-deployments.yaml` | master | 3 deployments: nginx, httpd, redis |
| `03-upgrade-master.sh` | master | full control plane + kubelet upgrade |
| `04-upgrade-worker.sh` | worker | worker upgrade |
| `05-etcd-restore.sh` | master | restore snapshot, re-sync upgraded config |
| `original_setup_reference/` | — | original both.sh / master_only.sh from Chapter00 |

### Versions
Default: **OLD = 1.34 → NEW = 1.35**. kubeadm upgrades only **one minor at a time**.
To use other versions, pass them as variables:
```bash
sudo K8S_VERSION=1.33 bash ScriptForBothNode.sh        # old
sudo NEW_VERSION=1.34 bash 03-upgrade-master.sh       # new (= old + 1)
sudo NEW_VERSION=1.34 bash 04-upgrade-worker.sh
```
The upgrade scripts pick the **latest patch** of the new minor automatically.

---

## Prerequisites
- 2 Ubuntu 22.04/24.04 VMs, min **2 vCPU / 2 GB RAM** each (master 4 GB recommended)
- Both VMs can reach each other; open ports 6443, 2379-2380, 10250, 10257, 10259 (master), 10250 + 30000-32767 (worker), UDP 4789 (Calico VXLAN)
- Unique hostnames: `sudo hostnamectl set-hostname master` / `worker`
- Copy this folder to both VMs (or `git clone` your repo) and `chmod +x *.sh`

---

## PART 1 — Cluster setup on OLD version

### 1. Both nodes
```bash
cd Chapter15Cluster
chmod +x *.sh
sudo bash ScriptForBothNode.sh
```

### 2. Master only
```bash
sudo bash ScriptFormaster.sh
```
At the end the join command is printed and **saved in the same folder**:
```bash
cat worker_join.sh            # also at /root/worker_join.sh
```

### 3. Worker — paste the join command
```bash
sudo kubeadm join <MASTER_IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```
Token expired? Regenerate on master: `sudo kubeadm token create --print-join-command`

### 4. Verify (master)
```bash
kubectl get nodes -o wide          # both Ready, VERSION v1.34.x
kubectl get pods -n kube-system
```

---

## PART 2 — etcd backup (OLD version)
```bash
sudo bash 01-etcd-backup.sh
```
Creates `/opt/etcd-backup/etcd-snapshot-before-upgrade.db` + copies of pki & manifests.

Manual command (for exam practice):
```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/etcd-snapshot-before-upgrade.db

etcdutl snapshot status /opt/etcd-backup/etcd-snapshot-before-upgrade.db -w table
```

---

## PART 3 — Create 3 new deployments (AFTER backup)
```bash
kubectl apply -f 02-demo-deployments.yaml
kubectl get deploy,pods -n upgrade-demo -o wide
```
These are **not** in the backup.

---

## PART 4 — Upgrade cluster (all components)

### 4a. Master
```bash
sudo NEW_VERSION=1.35 bash 03-upgrade-master.sh
```
What it does:
1. Switches apt repo `pkgs.k8s.io/.../v1.35`
2. Upgrades **kubeadm**
3. `kubeadm upgrade plan`
4. `kubeadm upgrade apply v1.35.x` → kube-apiserver, kube-controller-manager, kube-scheduler, **etcd**, kube-proxy, CoreDNS, certificates renewed
5. `kubectl drain master`
6. Upgrades **kubelet + kubectl**, restarts kubelet
7. `kubectl uncordon master`

Check:
```bash
kubectl get nodes        # master v1.35.x, worker still v1.34.x (allowed skew)
```

### 4b. Worker
On **master**:
```bash
kubectl drain worker --ignore-daemonsets --delete-emptydir-data
```
On **worker**:
```bash
sudo NEW_VERSION=1.35 bash 04-upgrade-worker.sh
```
On **master**:
```bash
kubectl uncordon worker
kubectl get nodes -o wide             # both v1.35.x
kubectl get deploy -n upgrade-demo    # the 3 deployments survived the upgrade
```

---

## PART 5 — Restore etcd backup on NEW version
```bash
sudo bash 05-etcd-restore.sh
```
Steps inside:
1. Move static pod manifests to `/etc/kubernetes/manifests-parked` → apiserver & etcd stop
2. Move `/var/lib/etcd` aside (`/var/lib/etcd.old-<timestamp>`)
3. `etcdutl snapshot restore` into `/var/lib/etcd`
4. Move manifests back → control plane starts
5. `kubeadm upgrade apply <current version>` — re-syncs cluster objects that the old snapshot rolled back (kubeadm-config ConfigMap, kube-proxy & CoreDNS images)

### Expected result
```bash
kubectl get ns upgrade-demo     # NotFound  -> 3 deployments gone (created after backup)
kubectl get nodes -o wide       # still v1.35.x (binaries are not in etcd)
```
**Key learning:** etcd holds cluster *state* only. A restore rewinds objects to snapshot time; it does not downgrade binaries.

---

## Troubleshooting
| Problem | Fix |
|---|---|
| Worker `NotReady` | `kubectl get pods -n kube-system -o wide` — wait for calico-node; check UDP 4789 open |
| `drain` blocked by PDB / bare pods | add `--force` |
| `kubeadm upgrade plan` shows no version | apt repo not switched; check `/etc/apt/sources.list.d/kubernetes.list` |
| Pods stuck after restore | `sudo systemctl restart kubelet` on both nodes; delete stuck pods |
| Restore went wrong | etcd old data is at `/var/lib/etcd.old-*` — park manifests, move it back |

## Reset & start again
```bash
sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d /root/.kube $HOME/.kube /var/lib/etcd* /opt/etcd-backup
```
