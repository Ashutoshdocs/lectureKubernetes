# Chapter16_HACluster — HA kubeadm cluster: 1 HA VM + 3 control planes + 3 workers

What this demo shows:
1. Create the VMs from the CLI (password login)
2. Build an HA cluster with **stacked etcd** (etcd runs on each control plane) behind an **HA VM running HAProxy**
3. **Who is "primary"** — etcd Raft leader + controller-manager/scheduler leaders
4. **How data is replicated** to the other two etcd members
5. **Stop the leader** control plane → watch a **new leader** get elected
6. **Bring it back** → it rejoins as a **follower (secondary)**
7. **Create a new VM and add it to the cluster** fully via CLI

**You run all demo commands from the HA VM.**

```text
                 You (SSH) ──►  vm-k8s-lb  10.0.1.10   = "HA VM"
                                ├─ HAProxy  k8s-api:6443  (API load balancer)
                                ├─ kubectl, etcdctl, az CLI  (admin box)
                                └─ runs 01/02/03/04/05 demo scripts
                                       │ round-robin + health check every 3s
             ┌─────────────────────────┼─────────────────────────┐
             ▼                         ▼                         ▼
     vm-k8s-cp1 10.0.1.11      vm-k8s-cp2 10.0.1.12      vm-k8s-cp3 10.0.1.13
     apiserver :6443           apiserver :6443           apiserver :6443
     etcd  ◄────── Raft replication ──────► etcd ◄──────────────► etcd
     controller-manager / scheduler  (only ONE active at a time, via Lease)
             ▲                         ▲                         ▲
             └──── kubelets on every node talk to k8s-api:6443 (HA VM) ────┘
     vm-k8s-worker1 10.0.1.21   vm-k8s-worker2 10.0.1.22   vm-k8s-worker3 10.0.1.23
     (later)  vm-k8s-worker4 10.0.1.24  ← added via 05-add-new-node.sh
```

**Why an HA VM?** An HA cluster needs **one stable API address** (`controlPlaneEndpoint`) that keeps working when any control plane dies. Every node and kubectl talk to `k8s-api:6443`, which points to the HA VM. HAProxy forwards each request to a healthy apiserver and drops a dead one within ~6 s.

> **Production note:** in this demo the HA VM itself is a single point of failure. In production you'd use 2 HAProxy VMs + keepalived (on-prem), or a cloud load balancer. The control plane HA shown here is the same either way.

---

## Files

| File | Run on | Purpose |
|---|---|---|
| `cluster.env` | — | **all names, IPs, versions, Azure settings — edit here only** |
| `00-create-vms.sh` | laptop / Cloud Shell | RG, VNet, NSG, **7 VMs** (HA VM + 3 CP + 3 workers), password login |
| `ScriptForHAVM.sh` | **HA VM** (first) | HAProxy (API LB + stats), kubectl, Azure CLI |
| `ScriptForAllNodes.sh` | 6 cluster nodes | containerd, kubeadm/kubelet/kubectl, `k8s-api` → HA VM |
| `ScriptForFirstMaster.sh` | vm-k8s-cp1 | `kubeadm init` (HA), Calico, join files **in same folder**, access bundle for HA VM |
| `HAVM-GetClusterAccess.sh` | **HA VM** | copies kubeconfig + etcd client certs from cp1 (password), installs etcdctl |
| `generate-join.sh` | any control plane | fresh `join_controlplane.sh` + `join_worker.sh` (when tokens expire) |
| `etcd-env.sh` | (sourced) | etcd TLS env + helper functions |
| `01-show-leaders.sh` | **HA VM** | etcd leader/followers, lease holders, HAProxy backends, nodes |
| `02-replication-demo.sh` | **HA VM** | writes data, reads it from **each** etcd member |
| `03-watch-cluster.sh` | **HA VM** | live view during failover |
| `04-vm-power.sh` | **HA VM** (or laptop) | `stop` / `start` / `status` of VMs |
| `05-add-new-node.sh` | **HA VM** (or laptop) | create VM + install + join **fully via CLI** |
| `99-delete-all.sh` | laptop / HA VM | delete everything |

---

## PART 1 — Create the VMs (laptop or Azure Cloud Shell)

Before you start:
- **Azure CLI**: Cloud Shell has it. Locally: `az login`.
- **Quota**: 6 × Standard_B2s + 1 × B1ms = **13 vCPUs**, and the extra node later makes 15. Check *Subscription → Usage + quotas → Standard BS Family vCPUs* for your region. Change `VM_SIZE`/`LOCATION` in `cluster.env` if needed.

```bash
bash 00-create-vms.sh          # asks for the VM password (12+ chars, mixed)
# or: ADMIN_PASSWORD='YourStr0ng!Pass' bash 00-create-vms.sh
```
Output is a table of private and public IPs.

> `SSH_SOURCE="*"` opens port 22 to the internet (password login). For anything beyond a short demo, set it to `<your-ip>/32` in `cluster.env`.

From here on, **SSH to the HA VM** and work from there:
```bash
ssh azureuser@<PublicIP of vm-k8s-lb>
```
To reach the other VMs, hop from the HA VM: `ssh vm-k8s-cp1` (same password). Or SSH to their public IPs directly.

---

## PART 2 — Build the cluster

Get this folder onto **all 7 VMs**, e.g.:
```bash
git clone https://github.com/Ashutoshdocs/lectureKubernetes.git
cd lectureKubernetes/CKA/Chapter16_HACluster && chmod +x *.sh
```

### 2.1 HA VM first
```bash
sudo bash ScriptForHAVM.sh
```
The backends show DOWN for now, which is expected because there are no apiservers yet.

### 2.2 All 6 cluster nodes
```bash
sudo bash ScriptForAllNodes.sh
```

### 2.3 vm-k8s-cp1 only
```bash
sudo bash ScriptForFirstMaster.sh
```
This first checks that `k8s-api:6443` (the HA VM) is reachable, then runs `kubeadm init`.
At the end it:
- saves `join_controlplane.sh` and `join_worker.sh` **in this same folder** and prints both commands
- saves `~/lb-bundle.tgz`, the kubeconfig + etcd client certs for the HA VM

### 2.4 vm-k8s-cp2 and vm-k8s-cp3
Paste the control-plane join command as root:
```bash
sudo kubeadm join k8s-api:6443 --token ... --discovery-token-ca-cert-hash sha256:... \
     --control-plane --certificate-key <key>
```
The certificate key is valid for **2 hours**. If it expires, run `sudo bash generate-join.sh` on cp1.

### 2.5 The 3 workers
```bash
sudo kubeadm join k8s-api:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

### 2.6 Give the HA VM cluster access (on HA VM, **no sudo**)
```bash
bash HAVM-GetClusterAccess.sh       # asks for the VM password (scp from cp1)
kubectl get nodes -o wide           # 6 nodes Ready
```

### 2.7 Azure CLI on the HA VM (for PART 5–7)
```bash
az login --use-device-code          # open the link on your laptop, enter the code
```

---

## PART 3 — Who is primary, and who is secondary? (HA VM)
```bash
sudo bash 01-show-leaders.sh
```
Concept to explain:
- Kubernetes has **no single primary control plane**. Each component handles HA its own way.
- **etcd** uses **Raft**. One member is the **LEADER** and the others are **followers**. Every write goes to the leader, and is committed once a **majority (2 of 3)** has stored it.
- **kube-controller-manager** and **kube-scheduler** run on all 3 nodes, but only the **Lease holder** is active. The others stand by.
- **kube-apiserver** is active on all 3. HAProxy on the HA VM spreads requests across them, which you'll see in the *HAProxy backends* section.

Example output:
```text
NAME          ENDPOINT                  ROLE      TERM  RAFT-INDEX  REVISION
vm-k8s-cp1    https://10.0.1.11:2379    LEADER    2     4512        3901
vm-k8s-cp2    https://10.0.1.12:2379    follower  2     4512        3901
vm-k8s-cp3    https://10.0.1.13:2379    follower  2     4512        3901

etcd Raft LEADER:         vm-k8s-cp1
kube-controller-manager:  vm-k8s-cp1
kube-scheduler:           vm-k8s-cp2
```
The leader is often cp1, but it doesn't have to be. Note who it is for PART 5.

HAProxy stats page (from the HA VM): `curl -s http://localhost:8404/stats\;csv | cut -d, -f1,2,18`

---

## PART 4 — How data is replicated (HA VM)
```bash
sudo bash 02-replication-demo.sh
```
1. Sends a write (`/demo/message`) to a **follower** on purpose. The follower forwards it to the leader, which commits it once 2 of 3 have it.
2. Creates namespace `ha-demo`, a ConfigMap and a 3-replica Deployment through the API (via HAProxy).
3. Reads them back from **each member separately** with `--consistency=s` (serializable). That answer comes from the member's **own local copy**, so the data really is on all 3 disks.
4. Shows the same **REVISION / RAFT-INDEX** on all members, meaning they are fully in sync.

Manual version (exam style, on the HA VM):
```bash
sudo -i; cd <this folder>; source etcd-env.sh
etcdctl --endpoints=https://10.0.1.12:2379 put /demo/hello world      # write via cp2
for ip in 10.0.1.11 10.0.1.12 10.0.1.13; do
  etcdctl --endpoints=https://$ip:2379 get /demo/hello --consistency=s
done
```

---

## PART 5 — Stop the leader → new leader is elected

Open **two SSH sessions to the HA VM**:

**Session A**: live view
```bash
sudo bash 03-watch-cluster.sh
```

**Session B**: stop the current leader (e.g. cp1)
```bash
bash 04-vm-power.sh stop vm-k8s-cp1
```

What you'll see in session A:

| Time | What happens |
|---|---|
| ~1–2 s | Followers miss heartbeats and hold an election. **New LEADER** appears, and **TERM goes up by 1** |
| ~6 s | HAProxy marks `vm-k8s-cp1` **DOWN**; kubectl keeps working through cp2/cp3 |
| ~15 s | If cp1 held the controller-manager/scheduler Lease, it expires and **another node takes it** |
| ~40 s | `vm-k8s-cp1` shows **NotReady** |
| always | Members up **2/3**, so quorum is kept and the cluster still accepts writes |

Prove it still works while cp1 is down (session B):
```bash
kubectl -n ha-demo scale deploy ha-web --replicas=5
kubectl create deployment while-cp1-down --image=nginx:1.27
sudo bash 02-replication-demo.sh     # cp1 shows DOWN, the other 2 have the data
```

**Quorum rule:** with 3 members you can lose **1**. If you stop a second control plane, etcd loses quorum. The API then **can't accept writes**, though running pods keep running. Try it, then start them again.

---

## PART 6 — Bring the first one back as secondary (HA VM)
```bash
bash 04-vm-power.sh start vm-k8s-cp1
```
On boot, kubelet starts the static pods (etcd and apiserver). In session A:
- cp1 comes back as a **follower**. Leadership does **not** move back, because Raft has no "preferred" leader.
- cp1's RAFT-INDEX / REVISION **catches up** to the others, replaying everything it missed, including `while-cp1-down`.
- HAProxy marks it **UP** again, and the node becomes Ready.

```bash
sudo bash 01-show-leaders.sh
sudo -i; cd <this folder>; source etcd-env.sh
etcdctl --endpoints=https://10.0.1.11:2379 get /registry/deployments/default/while-cp1-down --keys-only --consistency=s
```

---

## PART 7 — Create a new VM and add it to the cluster (HA VM, CLI only)
```bash
bash 05-add-new-node.sh                                   # vm-k8s-worker4 / 10.0.1.24 as worker
# custom:
bash 05-add-new-node.sh vm-k8s-worker5 10.0.1.25 worker
bash 05-add-new-node.sh vm-k8s-cp4     10.0.1.14 controlplane
```
The script uses `az vm run-command`, so no SSH is needed:
1. `az vm create` (password login)
2. Runs `ScriptForAllNodes.sh` on the new VM, so `k8s-api` points to the HA VM
3. Asks a running control plane for a fresh token (and certificate key, for a control plane)
4. Runs `kubeadm join` on the new VM
5. Prints `kubectl get nodes`
6. For a control plane, also **adds it to HAProxy** on the HA VM and reloads it

Then: `kubectl get nodes -o wide`

Manual way, same result:
```bash
# on any control plane
sudo bash generate-join.sh
# on the new VM
sudo bash ScriptForAllNodes.sh && sudo bash join_worker.sh
```
> Adding a 4th control plane gives 4 etcd members, so quorum becomes 3 and you can still lose only 1. That's why HA clusters use **odd** counts (3, 5).

---

## Troubleshooting
| Problem | Fix |
|---|---|
| `QuotaExceeded` on VM create | lower count/size or request quota for that VM family/region |
| `ScriptForFirstMaster.sh`: HA VM not reachable | run `ScriptForHAVM.sh` on vm-k8s-lb; `systemctl status haproxy` there |
| join hangs at `k8s-api:6443` | on HA VM: `echo 'show stat' \| sudo socat stdio /run/haproxy/admin.sock \| cut -d, -f1,2,18`; on node: `grep k8s-api /etc/hosts` |
| join: `certificate key ... not found` / expired | `sudo bash generate-join.sh` on a control plane |
| `HAVM-GetClusterAccess.sh`: scp permission denied | wrong password, or `ScriptForFirstMaster.sh` didn't finish (no `~/lb-bundle.tgz` on cp1) |
| Nodes NotReady after setup | wait for `calico-node` pods; `kubectl get pods -n kube-system -o wide` |
| etcd member DOWN after VM start | wait 30–60 s; on that node `sudo crictl ps \| grep etcd` |
| `az` errors on HA VM | `az login --use-device-code`; `az account set -s <subscription>` |

## Clean up (stop billing)
```bash
bash 99-delete-all.sh
```
