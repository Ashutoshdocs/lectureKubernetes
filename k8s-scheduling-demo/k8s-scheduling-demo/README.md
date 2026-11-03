# Kubernetes Scheduling Demo — Zones, Affinity, Taints, Cordon & Drain

A hands-on, step-by-step demo on a **6-node kubeadm cluster on Azure** covering:

| # | Topic | Manifest |
|---|-------|----------|
| 0 | Labels — add, check, overwrite, remove | `scripts/label-nodes.sh` |
| 1 | Node affinity (required + preferred) | `01-*.yaml`, `02-*.yaml` |
| 2 | Node anti-affinity (`NotIn` / `DoesNotExist`) | `03-node-anti-affinity.yaml` |
| 3 | Pod affinity (same node) | `04-pod-affinity.yaml` |
| 4 | Pod anti-affinity (one per node) | `05-pod-anti-affinity.yaml` |
| 5 | **topologyKey = zone** (anti-affinity, affinity, spread) | `06-*`, `07-*`, `08-*.yaml` |
| 6 | Taint / untaint, tolerations, NoExecute | `09-*`, `11-*.yaml` |
| 7 | Cordon / uncordon | — |
| 8 | Drain (with PodDisruptionBudget) | `10-drain-demo.yaml` |

---

## Cluster layout

```
                    ┌──────────────────────────┐
                    │  k8s-master  10.10.1.10  │  control plane
                    │  taint: control-plane    │  (no workloads)
                    └────────────┬─────────────┘
          ┌──────────────────────┴───────────────────────┐
   ┌──────┴──────────── zone-a ──────────┐   ┌────────── zone-b ───────────┐
   │ worker-a1  10.10.1.11  disktype=ssd │   │ worker-b1 10.10.1.21  ssd   │
   │ worker-a2  10.10.1.12  disktype=hdd │   │ worker-b2 10.10.1.22  hdd   │
   │ worker-a3  10.10.1.13  disktype=hdd │   └─────────────────────────────┘
   └─────────────────────────────────────┘
```

| Node | Role | Private IP | `topology.kubernetes.io/zone` | `disktype` |
|------|------|-----------|------|-----|
| k8s-master | control-plane | 10.10.1.10 | — | — |
| worker-a1 | worker | 10.10.1.11 | zone-a | ssd |
| worker-a2 | worker | 10.10.1.12 | zone-a | hdd |
| worker-a3 | worker | 10.10.1.13 | zone-a | hdd |
| worker-b1 | worker | 10.10.1.21 | zone-b | ssd |
| worker-b2 | worker | 10.10.1.22 | zone-b | hdd |

> The master carries the taint `node-role.kubernetes.io/control-plane:NoSchedule`, so normal pods
> never land there — you have **5 schedulable workers**. This matters in demo 4.

## Repository layout

```
k8s-scheduling-demo/
├── README.md
├── azure/
│   ├── create-vms.ps1          # 6 Trusted Launch B2s VMs, password auth
│   ├── cloud-init-k8s.yaml     # installs containerd + kubeadm/kubelet/kubectl on every VM
│   ├── stop-start-vms.ps1      # deallocate / start all VMs (save money)
│   └── delete-vms.ps1          # delete the whole resource group
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 01-node-affinity-required.yaml
│   ├── 02-node-affinity-preferred.yaml
│   ├── 03-node-anti-affinity.yaml
│   ├── 04-pod-affinity.yaml
│   ├── 05-pod-anti-affinity.yaml
│   ├── 06-zone-pod-anti-affinity.yaml
│   ├── 07-zone-pod-affinity.yaml
│   ├── 08-topology-spread.yaml
│   ├── 09-taint-toleration.yaml
│   ├── 10-drain-demo.yaml
│   └── 11-noexecute-toleration.yaml
└── scripts/
    ├── label-nodes.sh          # base labels (idempotent)
    ├── show-placement.sh       # pod -> node -> zone table + counts
    └── reset.sh                # back to clean baseline between demos
```

---

# Part A — Build the infrastructure

## A1. Prerequisites (your laptop)

- Azure subscription with quota for **12 vCPUs of the B-series family** in the region (6 × B2s = 12 vCPU).
  Check: `az vm list-usage --location centralindia -o table | Select-String "Standard BS Family"`
- Azure CLI 2.50+ — `az --version`
- PowerShell 7+ (recommended) or Windows PowerShell 5.1

## A2. Create the 6 VMs

```powershell
cd k8s-scheduling-demo/azure
az login
./create-vms.ps1                                # default region centralindia
# Options:
./create-vms.ps1 -Location southindia
./create-vms.ps1 -UseAzureZones                 # zone-a VMs -> Azure AZ 1, zone-b -> AZ 2
./create-vms.ps1 -AutoShutdownUtc 1630          # auto-stop daily at 22:00 IST
```

What the script does:

1. Checks you're logged in and that `Standard_B2s` is offered in the region.
2. Prompts for the admin password **securely** (never echoed, never on disk) and validates Azure's
   complexity rule (12–72 chars, 3 of 4 character classes).
3. Detects your public IP and allows **SSH only from your IP** in the NSG.
4. Creates RG `rg-k8s-scheduling-demo`, NSG, VNet `10.10.0.0/16`, subnet `10.10.1.0/24`.
5. Creates 6 VMs with **Trusted Launch**: Gen2 Ubuntu 22.04 image + `--security-type TrustedLaunch`
   + `--enable-secure-boot true` + `--enable-vtpm true` + `--enable-integrity-monitoring`
   (Guest Attestation extension), static private IPs, Standard public IP, StandardSSD OS disk.
6. Passes `cloud-init-k8s.yaml` as custom data → every VM gets containerd and kubeadm automatically.
7. Prints a verification table — confirm `Security = TrustedLaunch`, `SecureBoot = True`, `vTPM = True`.

> **Secure Boot note:** Ubuntu's signed kernel works with Secure Boot. If you later install unsigned
> kernel modules (some GPU / custom drivers), they won't load — not relevant to this demo.

## A3. Wait for node prep

```bash
ssh azureuser@<k8s-master-public-ip>
cloud-init status --wait           # "status: done"
cat /var/log/k8s-prep-done         # K8S NODE PREP COMPLETE
kubeadm version && containerd --version
```

Check every VM (or just the master — they're identical).

---

# Part B — Bootstrap the Kubernetes cluster

## B1. Initialise the control plane (on **k8s-master**)

```bash
sudo kubeadm init \
  --apiserver-advertise-address=10.10.1.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --node-name k8s-master

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Save the `kubeadm join ...` line printed at the end. Lost it? Regenerate:

```bash
kubeadm token create --print-join-command
```

## B2. Install the pod network (Flannel)

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get pods -n kube-flannel -w      # wait for Running
```

## B3. Join the 5 workers

SSH into **each** worker (`worker-a1 … worker-b2`) and run the join command with sudo:

```bash
sudo kubeadm join 10.10.1.10:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

> Tip: from the master you can reach workers by name: `ssh azureuser@worker-a1` (names are in `/etc/hosts`).

## B4. Verify

```bash
kubectl get nodes -o wide        # 6 nodes, all Ready (~1 min after join)
kubectl describe node k8s-master | grep Taints
# Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

## B5. Copy the demo onto the master

```bash
# from your laptop
scp -r k8s-scheduling-demo azureuser@<k8s-master-public-ip>:~
# on the master
cd ~/k8s-scheduling-demo
chmod +x scripts/*.sh
```

All remaining commands run on **k8s-master** from `~/k8s-scheduling-demo`.

---

# Part C — The demos

> **Watch window:** open a second SSH session and keep this running:
> ```bash
> watch -n2 'kubectl get pods -n scheduling-demo -o wide'
> ```
> Between demos run `./scripts/reset.sh` to return to the clean baseline.

## Demo 0 — Labels: put, check, overwrite, remove

Labels are key/value pairs on objects. Every scheduling rule below matches on **node labels**.

### 0.1 Check the existing (built-in) labels

```bash
kubectl get nodes --show-labels
kubectl get node worker-a1 -o jsonpath='{.metadata.labels}' | jq
```

Built-in labels set by kubelet: `kubernetes.io/hostname`, `kubernetes.io/os`, `kubernetes.io/arch`.
kubeadm adds `node-role.kubernetes.io/control-plane` to the master. **There is no zone label yet** —
on a self-managed cluster you add it yourself (on AKS/EKS/GKE the cloud provider sets it).

### 0.2 Put a label

```bash
kubectl label node worker-a1 topology.kubernetes.io/zone=zone-a
kubectl label node worker-a2 topology.kubernetes.io/zone=zone-a
kubectl label node worker-a3 topology.kubernetes.io/zone=zone-a
kubectl label node worker-b1 topology.kubernetes.io/zone=zone-b
kubectl label node worker-b2 topology.kubernetes.io/zone=zone-b

kubectl label node worker-a1 worker-b1 disktype=ssd            # several nodes at once
kubectl label node worker-a2 worker-a3 worker-b2 disktype=hdd
kubectl label node worker-a1 worker-a2 worker-a3 worker-b1 worker-b2 node-role.kubernetes.io/worker=
```

(Shortcut: `./scripts/label-nodes.sh` does all of the above.)

### 0.3 Check labels

```bash
# Show chosen labels as columns  (-L = --label-columns)
kubectl get nodes -L topology.kubernetes.io/zone,disktype

# Filter by label  (-l = --selector)
kubectl get nodes -l topology.kubernetes.io/zone=zone-a
kubectl get nodes -l 'topology.kubernetes.io/zone in (zone-a,zone-b)'
kubectl get nodes -l 'disktype!=ssd'
kubectl get nodes -l '!node-role.kubernetes.io/control-plane'   # all non-masters
kubectl get nodes -l env                                          # nodes that HAVE key env

# One node, one label
kubectl get node worker-a1 -o jsonpath='{.metadata.labels.disktype}{"\n"}'
```

### 0.4 Overwrite a label

Changing an existing value **fails without `--overwrite`** — a safety net:

```bash
kubectl label node worker-a2 disktype=ssd
# error: 'disktype' already has a value (hdd), and --overwrite is false

kubectl label node worker-a2 disktype=ssd --overwrite
kubectl get nodes -L disktype
```

### 0.5 Remove a label (trailing minus)

```bash
kubectl label node worker-a2 disktype-
kubectl get node worker-a2 --show-labels | tr ',' '\n' | grep disktype   # nothing
kubectl label node worker-a2 disktype=hdd                                 # put it back
```

### 0.6 Labels on pods

```bash
kubectl run tmp --image=nginx:1.27-alpine -n scheduling-demo --labels="app=tmp,tier=fe"
kubectl label pod tmp -n scheduling-demo tier=backend --overwrite
kubectl get pods -n scheduling-demo --show-labels
kubectl delete pod tmp -n scheduling-demo
```

```bash
kubectl apply -f manifests/00-namespace.yaml     # (if not done yet)
```

---

## Demo 1 — Node affinity

Node affinity attracts pods to nodes based on **node labels**.

| Type | Behaviour |
|------|-----------|
| `requiredDuringSchedulingIgnoredDuringExecution` | **Hard** — no matching node → Pending |
| `preferredDuringSchedulingIgnoredDuringExecution` | **Soft** — scored by `weight` (1–100), falls back if needed |
| `IgnoredDuringExecution` | Changing labels later does **not** evict running pods |

### 1a. Required (hard) — only zone-a

```bash
kubectl apply -f manifests/01-node-affinity-required.yaml
./scripts/show-placement.sh na-required-zone-a
```

**Expected:** 4 pods spread across worker-a1/a2/a3, zero in zone-b.

**Prove it's hard** — cordon all zone-a nodes and scale up:

```bash
kubectl cordon worker-a1 worker-a2 worker-a3
kubectl scale deploy na-required-zone-a -n scheduling-demo --replicas=6
kubectl get pods -n scheduling-demo -l app=na-required-zone-a      # 2 Pending
kubectl describe pod -n scheduling-demo -l app=na-required-zone-a | grep -A3 Events | tail -4
# ... 2 node(s) didn't match Pod's node affinity/selector, 3 node(s) were unschedulable ...
kubectl uncordon worker-a1 worker-a2 worker-a3                     # Pending pods start
```

**Prove `IgnoredDuringExecution`** — remove the zone label from a node that has pods:

```bash
kubectl label node worker-a1 topology.kubernetes.io/zone-
./scripts/show-placement.sh na-required-zone-a     # pods on worker-a1 still Running!
kubectl label node worker-a1 topology.kubernetes.io/zone=zone-a
```

Running pods are untouched; only **new** pods are affected. (A deleted pod would not come back to worker-a1.)

### 1b. Preferred (soft) — ssd (w=80) and zone-b (w=20)

```bash
kubectl apply -f manifests/02-node-affinity-preferred.yaml
./scripts/show-placement.sh na-preferred-ssd
```

**Expected:** pods favour worker-b1 (ssd + zone-b = 100 points) and worker-a1 (ssd = 80).
Other scores (resource balance) also count, so distribution may not be 100% on those two.

**Prove it's soft:**

```bash
kubectl cordon worker-a1 worker-b1
kubectl scale deploy na-preferred-ssd -n scheduling-demo --replicas=8
./scripts/show-placement.sh na-preferred-ssd     # new pods run on hdd nodes, nothing Pending
kubectl uncordon worker-a1 worker-b1
```

> `nodeSelector` (used in 04-pod-affinity.yaml) is the simplest form — exact-match, hard, no operators.

```bash
./scripts/reset.sh
```

---

## Demo 2 — Node anti-affinity

There is **no `nodeAntiAffinity` field**. You express "stay away from nodes" with `nodeAffinity`
using `NotIn` or `DoesNotExist` (or with taints — Demo 6).

```bash
kubectl label node worker-b2 env=maintenance          # mark a node to avoid
kubectl apply -f manifests/03-node-anti-affinity.yaml
./scripts/show-placement.sh node-anti-affinity
```

**Expected:** all 3 pods on **worker-b1** only:
- zone-a excluded by `zone NotIn [zone-a]`
- worker-b2 excluded by `env NotIn [maintenance]`
- master excluded by `node-role.kubernetes.io/control-plane DoesNotExist`

Note: `NotIn` **also matches nodes that don't have the key at all** — that's why worker-b1 (no `env`) qualifies.

```bash
kubectl label node worker-b2 env-                       # remove the label
kubectl rollout restart deploy node-anti-affinity -n scheduling-demo
./scripts/show-placement.sh node-anti-affinity          # now b1 + b2
./scripts/reset.sh
```

---

## Demo 3 — Pod affinity (topologyKey: hostname)

Pod affinity places pods **relative to other pods** — "run me where pods with label X run".
`topologyKey` defines what "where" means:

| topologyKey | "Same place" means |
|---|---|
| `kubernetes.io/hostname` | same **node** |
| `topology.kubernetes.io/zone` | same **zone** (any node in it) |

```bash
kubectl apply -f manifests/04-pod-affinity.yaml
./scripts/show-placement.sh cache
./scripts/show-placement.sh web
```

**Expected:** `cache` on worker-b1 *or* worker-b2; all 3 `web` pods on **that same node**.

**What if the target pod is missing?**

```bash
kubectl scale deploy cache -n scheduling-demo --replicas=0
kubectl rollout restart deploy web -n scheduling-demo
kubectl get pods -n scheduling-demo -l app=web           # new pods Pending
kubectl describe pod -n scheduling-demo -l app=web | grep "didn't match pod affinity" | head -1
kubectl scale deploy cache -n scheduling-demo --replicas=1   # web pods follow cache
./scripts/reset.sh
```

---

## Demo 4 — Pod anti-affinity (topologyKey: hostname)

"Don't put me on a node that already runs a pod with label X" — classic HA pattern.

```bash
kubectl apply -f manifests/05-pod-anti-affinity.yaml
./scripts/show-placement.sh spread-per-node
```

**Expected:** 5 Running (one per worker), **1 Pending**:

```bash
kubectl get pods -n scheduling-demo --field-selector=status.phase=Pending
kubectl describe pod -n scheduling-demo <pending-pod> | tail -5
# 0/6 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
# 5 node(s) didn't match pod anti-affinity rules.
```

Scale to 5 and the Pending pod disappears: `kubectl scale deploy spread-per-node -n scheduling-demo --replicas=5`

> Use `preferred...` instead of `required...` if you want "spread if possible, but never block".

```bash
./scripts/reset.sh
```

---

## Demo 5 — topologyKey = zone ⭐

The same affinity rules, but the "domain" becomes a **zone**: all nodes sharing the same value of
`topology.kubernetes.io/zone` count as **one** place.

```
Domain "zone-a" = { worker-a1, worker-a2, worker-a3 }
Domain "zone-b" = { worker-b1, worker-b2 }
```

Nodes **without** the label (the master) are not part of any domain.

### 5a. Pod anti-affinity per zone (required → max 1 pod per zone)

```bash
kubectl apply -f manifests/06-zone-pod-anti-affinity.yaml
./scripts/show-placement.sh zone-ha-required
```

**Expected:** **1 pod in zone-a + 1 pod in zone-b + 1 Pending** — even though there are 5 free nodes.
That's the key insight: the rule counts **zones**, not nodes.

```bash
./scripts/show-placement.sh zone-ha-preferred
```

**Expected (soft version, 4 replicas):** both zones used, nothing Pending.

**Add a third zone** and watch the Pending pod schedule:

```bash
kubectl label node worker-a3 topology.kubernetes.io/zone=zone-c --overwrite
./scripts/show-placement.sh zone-ha-required    # 3 Running: zone-a, zone-b, zone-c
kubectl label node worker-a3 topology.kubernetes.io/zone=zone-a --overwrite
```

### 5b. Pod affinity per zone (same zone, not same node)

```bash
kubectl apply -f manifests/07-zone-pod-affinity.yaml
./scripts/show-placement.sh db
./scripts/show-placement.sh api
```

**Expected:** `db` on some zone-a node; the 3 `api` pods **spread across worker-a1/a2/a3** (same zone as db,
different nodes thanks to the soft hostname anti-affinity). Compare with Demo 3, where `topologyKey: hostname`
packed every `web` pod onto one node.

### 5c. topologySpreadConstraints (bonus — the modern way)

```bash
kubectl apply -f manifests/08-topology-spread.yaml
./scripts/show-placement.sh zone-spread
```

**Expected:** **3 in zone-a, 3 in zone-b** (`maxSkew: 1`) — even though zone-a has 3 nodes and zone-b only 2,
so zone-b nodes carry more pods each. Scale to 7 → 4/3 split; the counts never differ by more than 1.

| Want | Use |
|---|---|
| At most N per domain / strict isolation | `podAntiAffinity` required |
| Even balance across zones | `topologySpreadConstraints` |
| Co-locate with another app | `podAffinity` |

```bash
./scripts/reset.sh
```

---

## Demo 6 — Taints, untaint & tolerations

Affinity **attracts** pods; taints **repel** them. A taint is `key=value:effect` on a node.
A pod with a matching **toleration** is *allowed* (not forced) onto the node.

| Effect | New pods without toleration | Running pods without toleration |
|---|---|---|
| `NoSchedule` | blocked | stay |
| `PreferNoSchedule` | avoided if possible | stay |
| `NoExecute` | blocked | **evicted** (immediately or after `tolerationSeconds`) |

### 6.1 Check existing taints

```bash
kubectl describe node k8s-master | grep -i taints
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
```

### 6.2 Taint a node (NoSchedule)

```bash
kubectl taint nodes worker-b2 dedicated=gpu:NoSchedule
kubectl describe node worker-b2 | grep Taints
# Taints: dedicated=gpu:NoSchedule

kubectl apply -f manifests/09-taint-toleration.yaml
./scripts/show-placement.sh no-toleration     # 5 pods, NONE on worker-b2
./scripts/show-placement.sh gpu-tolerant      # 2 pods, both on worker-b2
kubectl get pod on-master -n scheduling-demo -o wide   # runs on k8s-master (tolerates control-plane taint)
```

Why `gpu-tolerant` also needs node affinity: a toleration only **permits** worker-b2. Without the affinity,
the pods could land anywhere. **Taint + toleration + affinity = dedicated nodes.**

### 6.3 Untaint (trailing minus)

```bash
kubectl taint nodes worker-b2 dedicated=gpu:NoSchedule-   # remove exact taint
# or: kubectl taint nodes worker-b2 dedicated-            # remove all taints with key "dedicated"
kubectl rollout restart deploy no-toleration -n scheduling-demo
./scripts/show-placement.sh no-toleration                 # worker-b2 now used too
```

> Removing the master's taint (`kubectl taint nodes k8s-master node-role.kubernetes.io/control-plane:NoSchedule-`)
> makes the master schedulable — fine for labs, not for production. Re-add it with the same command minus the `-`.

### 6.4 NoExecute — eviction of running pods

```bash
kubectl apply -f manifests/11-noexecute-toleration.yaml
kubectl get pods -n scheduling-demo -l demo=noexecute -o wide     # 3 pods on worker-a3

kubectl taint nodes worker-a3 maintenance=true:NoExecute
kubectl get pods -n scheduling-demo -l demo=noexecute -w
```

**Expected:** `evict-now` terminates immediately, `evict-after-60` terminates ~60 s later, `stay-forever` keeps running.
(Bare pods aren't recreated; Deployment pods would be rescheduled elsewhere.)

```bash
kubectl taint nodes worker-a3 maintenance=true:NoExecute-
./scripts/reset.sh
```

---

## Demo 7 — Cordon / uncordon

`cordon` marks a node **unschedulable** (`spec.unschedulable: true`, adds taint
`node.kubernetes.io/unschedulable:NoSchedule`). **Existing pods keep running.**

```bash
kubectl apply -f manifests/10-drain-demo.yaml
./scripts/show-placement.sh drain-app          # 6 pods over 5 workers

kubectl cordon worker-a1
kubectl get nodes
# worker-a1   Ready,SchedulingDisabled   worker ...
./scripts/show-placement.sh drain-app          # pods on worker-a1 STILL running

kubectl scale deploy drain-app -n scheduling-demo --replicas=10
./scripts/show-placement.sh drain-app          # new pods avoid worker-a1

kubectl uncordon worker-a1
kubectl get nodes                              # Ready again
kubectl scale deploy drain-app -n scheduling-demo --replicas=6
```

> Uncordon does **not** move pods back. The scheduler only places new pods; rebalance with
> `kubectl rollout restart deploy <name>` (or the descheduler project).

---

## Demo 8 — Drain (proper maintenance procedure)

`drain` = **cordon + evict every pod** (respecting PodDisruptionBudgets). Used before patching, rebooting or removing a node.

Setup (from Demo 7, still applied): `drain-app` (6 replicas, PDB `minAvailable: 4`) + `orphan-pod` on worker-a2.

### Step 1 — See what's on the node

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=worker-a2
kubectl get pdb -n scheduling-demo
# NAME            MIN AVAILABLE   ALLOWED DISRUPTIONS
# drain-app-pdb   4               2
```

### Step 2 — Naive drain (fails on purpose)

```bash
kubectl drain worker-a2
```

It cordons the node but refuses to continue:
- `cannot delete DaemonSet-managed Pods` (kube-proxy, kube-flannel) → need `--ignore-daemonsets`
- `cannot delete Pods with local storage` (emptyDir in drain-app) → need `--delete-emptydir-data`
- `cannot delete Pods that declare no controller` (orphan-pod) → need `--force`

### Step 3 — Dry run first

```bash
kubectl drain worker-a2 --ignore-daemonsets --delete-emptydir-data --force --dry-run=client
```

### Step 4 — Real drain

```bash
kubectl drain worker-a2 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30 \
  --timeout=300s
```

Watch the second terminal: drain-app pods on worker-a2 are evicted and recreated on other nodes.
The PDB guarantees ≥4 replicas stay up throughout. **orphan-pod is gone for good** — no controller recreates it.

### Step 5 — Verify

```bash
kubectl get nodes                                               # worker-a2 Ready,SchedulingDisabled
kubectl get pods -A -o wide --field-selector spec.nodeName=worker-a2   # only DaemonSet pods left
./scripts/show-placement.sh drain-app                           # 6/6 Running on other nodes
```

### Step 6 — Do the maintenance

```bash
ssh azureuser@worker-a2 'sudo apt-get update && sudo apt-get -y upgrade && sudo reboot'
kubectl get nodes -w           # NotReady -> Ready
```

### Step 7 — Return the node to service

```bash
kubectl uncordon worker-a2
kubectl get nodes
```

### Bonus — PDB blocking a drain

```bash
kubectl patch pdb drain-app-pdb -n scheduling-demo -p '{"spec":{"minAvailable":6}}'
kubectl drain worker-b1 --ignore-daemonsets --delete-emptydir-data --timeout=60s
# error when evicting pods/"drain-app-..." : Cannot evict pod as it would violate the pod's disruption budget.
# drain retries until --timeout, then fails. The node stays cordoned!
kubectl uncordon worker-b1
kubectl patch pdb drain-app-pdb -n scheduling-demo -p '{"spec":{"minAvailable":4}}'
```

### Removing a node permanently

```bash
kubectl drain worker-b2 --ignore-daemonsets --delete-emptydir-data --force
kubectl delete node worker-b2
ssh azureuser@worker-b2 'sudo kubeadm reset -f'
# re-add later: kubeadm token create --print-join-command  -> run on worker-b2
```

```bash
./scripts/reset.sh
```

---

# Cheat sheet

```bash
# ---- Labels
kubectl label node <n> key=value                 # add
kubectl label node <n> key=value --overwrite     # change
kubectl label node <n> key-                      # remove
kubectl get nodes -L key1,key2                   # show as columns
kubectl get nodes -l key=value                   # filter
kubectl get nodes --show-labels                  # all

# ---- Taints
kubectl taint nodes <n> key=value:NoSchedule     # add  (NoSchedule|PreferNoSchedule|NoExecute)
kubectl taint nodes <n> key=value:NoSchedule-    # remove exact
kubectl taint nodes <n> key-                     # remove all with key
kubectl describe node <n> | grep Taints

# ---- Cordon / drain
kubectl cordon <n>
kubectl uncordon <n>
kubectl drain <n> --ignore-daemonsets --delete-emptydir-data [--force] [--dry-run=client]

# ---- Why is my pod Pending?
kubectl describe pod <pod> -n scheduling-demo | sed -n '/Events/,$p'
kubectl get events -n scheduling-demo --sort-by=.lastTimestamp | tail
```

| Feature | Matches on | Hard | Soft |
|---|---|---|---|
| nodeSelector | node labels | ✔ | — |
| nodeAffinity | node labels | required… | preferred… (weight) |
| node anti-affinity | node labels (`NotIn`, `DoesNotExist`) | required… | preferred… |
| podAffinity | labels of **pods** in a topology domain | required… | preferred… |
| podAntiAffinity | labels of **pods** in a topology domain | required… | preferred… |
| topologySpreadConstraints | pod counts per domain | DoNotSchedule | ScheduleAnyway |
| taint + toleration | node taints | NoSchedule / NoExecute | PreferNoSchedule |

# Troubleshooting

| Symptom | Fix |
|---|---|
| `create-vms.ps1`: SKU not available / quota | Try `-Location southindia` or request B-series quota increase |
| `--security-type` unknown | Upgrade Azure CLI: `az upgrade` |
| Node `NotReady` after join | Flannel not installed, or `kubectl -n kube-flannel logs ds/kube-flannel-ds` |
| `kubeadm init` preflight swap error | `sudo swapoff -a` |
| Zone demos: all pods Pending | Zone labels missing → `./scripts/label-nodes.sh` |
| Pods stuck `ContainerCreating` | `kubectl describe pod` → image pull; check VM outbound internet |
| SSH times out | Your public IP changed → update NSG rule `Allow-SSH` source |

# Cost & cleanup

6 × B2s ≈ 12 vCPU running 24×7 adds up — stop the VMs when you're not demoing:

```powershell
./azure/stop-start-vms.ps1 -Action stop     # deallocate (disks still billed, compute not)
./azure/stop-start-vms.ps1 -Action start
./azure/delete-vms.ps1                      # delete everything
```

Inside the cluster: `kubectl delete ns scheduling-demo`.
