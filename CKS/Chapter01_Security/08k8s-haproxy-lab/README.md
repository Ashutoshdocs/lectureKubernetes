# Practical: HAProxy in front of two Kubernetes clusters, with per-user isolation

A hands-on lab where **two people (Manohar and Ashutosh Kumar)** each get their own
Kubernetes cluster, both reached through **one HAProxy load balancer**. The two
people log in to a single **bastion VM (`clusterwork`)** and run `kubectl` from
there. Manohar can only touch cluster 1 (API server 1 + worker 1); Ashutosh can
only touch cluster 2 (API server 2 + worker 2).

Everything is **password-based** and provisioned on **Azure**.

---

## 1. What you are building

```
                                 Internet
                                    │  ssh (password)
                                    ▼
                          ┌───────────────────┐
                          │   clusterwork VM   │   <-- Manohar & Ashutosh ssh here
                          │  (bastion, kubectl)│       and run kubectl
                          └─────────┬─────────-┘
                                    │  kubectl traffic (inside VNet)
                                    ▼
                          ┌───────────────────┐
                          │    haproxy-vm      │
                          │  :7001  ─────────► cluster 1   (Manohar)
                          │  :7002  ─────────► cluster 2   (Ashutosh)
                          │  :8404  stats page │
                          └───┬────────────┬───┘
              :7001 → :6443   │            │   :7002 → :6443
                              ▼            ▼
                   ┌──────────────┐   ┌──────────────┐
                   │ cluster1-cp  │   │ cluster2-cp  │
                   │ API server 1 │   │ API server 2 │
                   └──────┬───────┘   └──────┬───────┘
                          │                  │
                   ┌──────▼───────┐   ┌──────▼───────┐
                   │cluster1-worker│  │cluster2-worker│
                   │  (worker 1)   │  │  (worker 2)   │
                   └───────────────┘  └───────────────┘
```

| VM                | Role                                   | Belongs to      |
|-------------------|----------------------------------------|-----------------|
| `haproxy-vm`      | Single entry point, TCP router         | shared          |
| `cluster1-cp`     | Control plane / **API server 1**       | Cluster 1       |
| `cluster1-worker` | Worker node (**worker 1**)             | Cluster 1       |
| `cluster2-cp`     | Control plane / **API server 2**       | Cluster 2       |
| `cluster2-worker` | Worker node (**worker 2**)             | Cluster 2       |
| `clusterwork`     | Bastion; users SSH here, run `kubectl` | shared          |

**The routing rule you asked for**

* Manohar's kubeconfig points at `https://<haproxy>:7001` → HAProxy forwards to **API server 1**, whose pods land on **worker 1**. Manohar has **full (cluster-admin)** rights on cluster 1 only.
* Ashutosh's kubeconfig points at `https://<haproxy>:7002` → HAProxy forwards to **API server 2**, whose pods land on **worker 2**. Ashutosh has **full rights** on cluster 2 only.
* Manohar cannot use cluster 2 and Ashutosh cannot use cluster 1 — enforced by two things at once: each user's client certificate is signed by **only one cluster's CA**, and each user is bound to `cluster-admin` on **only one cluster**.

### Why two clusters (design note)
You described "API server 1 for Manohar, API server 2 for Ashutosh, and each user restricted to their own API server." Kubernetes RBAC is **cluster-wide**, so you cannot restrict a user to "one API server of the same cluster." The faithful way to give each person their own isolated API server + worker is **two clusters behind one HAProxy** — which is exactly this lab. HAProxy is what makes them look like one endpoint with two doors (`:7001`, `:7002`).

---

## 2. Prerequisites

* An Azure subscription and the Azure CLI installed on your laptop.
* Run `az login` once before starting.
* Basic SSH client.

> HAProxy here does **TCP (layer-4) pass-through** — it forwards raw `6443`
> traffic without decrypting it. That is essential: the client certificate in
> each kubeconfig reaches the API server untouched, so authentication and RBAC
> still work end-to-end.

---

## 3. Step-by-step

All scripts live in `scripts/`. Read the header of each script — it says exactly
where to run it.

### Step 0 — clone/copy the lab folder to your laptop
```bash
cd k8s-haproxy-lab
chmod +x scripts/*.sh
```

### Step 1 — create the 6 VMs (password auth)
Edit the variables at the top of `scripts/01-create-vms.sh` (resource group,
location, and especially `ADMIN_PASS`). Then:
```bash
bash scripts/01-create-vms.sh
```
At the end it prints a table of **public and private IPs**. Copy
`env.sh.example` to `env.sh`, paste the IPs in, and:
```bash
cp env.sh.example env.sh   # then edit
source env.sh
```
You now SSH to any VM with its **public** IP:
```bash
ssh $ADMIN_USER@$HAPROXY_PUB      # password = ADMIN_PASS you set
```

### Step 2 — prepare the 4 Kubernetes nodes
Copy and run `02-node-common.sh` on **each** of: `cluster1-cp`,
`cluster1-worker`, `cluster2-cp`, `cluster2-worker`.

Example for `cluster1-cp` (repeat for the other three):
```bash
scp scripts/02-node-common.sh $ADMIN_USER@$C1CP_PUB:/tmp/
ssh $ADMIN_USER@$C1CP_PUB 'sudo bash /tmp/02-node-common.sh'
```
This installs containerd + kubeadm/kubelet/kubectl and the required kernel
settings. **Do not** run it on `haproxy-vm` or `clusterwork`.

### Step 3 — build Cluster 1
On **`cluster1-cp`**, init the cluster (pass HAProxy's *private* IP so the API
server's TLS cert is valid when reached through HAProxy):
```bash
ssh $ADMIN_USER@$C1CP_PUB
sudo HAPROXY_IP=<HAPROXY_IP> bash /tmp/04-init-cluster.sh   # copy the script over first
```
> Copy the script first: `scp scripts/04-init-cluster.sh $ADMIN_USER@$C1CP_PUB:/tmp/`

The script prints a **`kubeadm join ...` command**. Copy it, then on
**`cluster1-worker`**:
```bash
ssh $ADMIN_USER@$C1WK_PUB
sudo kubeadm join <paste the join command from cluster1-cp>
```
Back on `cluster1-cp`, confirm both nodes are `Ready`:
```bash
kubectl get nodes
```

### Step 4 — build Cluster 2 (identical, different VMs)
On **`cluster2-cp`**:
```bash
scp scripts/04-init-cluster.sh $ADMIN_USER@$C2CP_PUB:/tmp/
ssh $ADMIN_USER@$C2CP_PUB 'sudo HAPROXY_IP=<HAPROXY_IP> bash /tmp/04-init-cluster.sh'
```
Copy its join command and run it on **`cluster2-worker`**:
```bash
ssh $ADMIN_USER@$C2WK_PUB 'sudo kubeadm join <paste cluster2 join command>'
```

### Step 5 — set up HAProxy
On **`haproxy-vm`**, install HAProxy and point its two frontends at the two
control-plane private IPs:
```bash
scp -r scripts/03-haproxy.sh haproxy/ $ADMIN_USER@$HAPROXY_PUB:/tmp/
ssh $ADMIN_USER@$HAPROXY_PUB
# on the vm (the script expects ../haproxy/haproxy.cfg next to it):
mkdir -p ~/lab/scripts ~/lab/haproxy
mv /tmp/03-haproxy.sh ~/lab/scripts/ && mv /tmp/haproxy/haproxy.cfg ~/lab/haproxy/
sudo C1CP_IP=<C1CP_IP> C2CP_IP=<C2CP_IP> bash ~/lab/scripts/03-haproxy.sh
```
Open `http://<haproxy public IP>:8404/stats` in a browser — you should see both
backends **UP** (green).

### Step 6 — set up the bastion + create the two people
On **`clusterwork`**:
```bash
scp scripts/06-clusterwork.sh $ADMIN_USER@$CLUSTERWORK_PUB:/tmp/
ssh $ADMIN_USER@$CLUSTERWORK_PUB 'sudo bash /tmp/06-clusterwork.sh'
```
This installs `kubectl` and creates two **Linux logins** with passwords:
`manohar` and `ashutosh` (change the passwords inside the script first).

### Step 7 — give each person their cluster (certs + RBAC + kubeconfig)
Create Manohar on **cluster 1**. Run on **`cluster1-cp`**:
```bash
scp scripts/07-make-user.sh $ADMIN_USER@$C1CP_PUB:/tmp/
ssh $ADMIN_USER@$C1CP_PUB \
  'sudo USER_NAME=manohar CLUSTER_NAME=cluster1 HAPROXY_IP=<HAPROXY_IP> PORT=7001 bash /tmp/07-make-user.sh'
```
This signs Manohar's client cert with cluster 1's CA, binds him to
`cluster-admin` on cluster 1, and writes `/tmp/manohar-kube/manohar.kubeconfig`
(server = HAProxy `:7001`).

Create Ashutosh on **cluster 2**. Run on **`cluster2-cp`**:
```bash
scp scripts/07-make-user.sh $ADMIN_USER@$C2CP_PUB:/tmp/
ssh $ADMIN_USER@$C2CP_PUB \
  'sudo USER_NAME=ashutosh CLUSTER_NAME=cluster2 HAPROXY_IP=<HAPROXY_IP> PORT=7002 bash /tmp/07-make-user.sh'
```

Now deliver each kubeconfig to the bastion into that person's home directory.
From your laptop:
```bash
# Manohar
ssh $ADMIN_USER@$C1CP_PUB
sudo cp /tmp/manohar-kube/manohar.kubeconfig /home/azureuser/manohar.kubeconfig
sudo chown azureuser:azureuser /home/azureuser/manohar.kubeconfig
chmod 600 /home/azureuser/manohar.kubeconfig
on git : scp $ADMIN_USER@$C1CP_PUB:/home/azureuser/manohar.kubeconfig /tmp/
         scp /tmp/manohar.kubeconfig $ADMIN_USER@$CLUSTERWORK_PUB:/tmp/
		 ssh $ADMIN_USER@$CLUSTERWORK_PUB 'sudo mkdir -p /home/manohar/.kube && sudo install -o manohar -g manohar -m 600 /tmp/manohar.kubeconfig /home/manohar/.kube/config'

# Ashutosh
ssh $ADMIN_USER@$C2CP_PUB
sudo cp /tmp/ashutosh-kube/ashutosh.kubeconfig /home/azureuser/ashutosh.kubeconfig
sudo chown azureuser:azureuser /home/azureuser/ashutosh.kubeconfig
chmod 600 /home/azureuser/ashutosh.kubeconfig
on git: scp $ADMIN_USER@$C2CP_PUB:/home/azureuser/ashutosh.kubeconfig /tmp/
        scp /tmp/ashutosh.kubeconfig $ADMIN_USER@$CLUSTER2WORK_PUB:/tmp/
		ssh $ADMIN_USER@$CLUSTER2WORK_PUB 'sudo mkdir -p /home/ashutosh/.kube && sudo install -o ashutosh -g ashutosh -m 600 /tmp/ashutosh.kubeconfig /home/ashutosh/.kube/config'
```

---

## 4. The demo (what the two users actually do)

### Manohar
```bash
ssh manohar@<clusterwork public IP>          # password: Manohar_Pass!2026
kubectl get nodes                             # -> sees cluster1-cp + cluster1-worker
kubectl config current-context                # -> manohar@cluster1
# deploy something; it will schedule onto worker 1
kubectl create deployment web --image=nginx --replicas=2
kubectl get pods -o wide                       # NODE column shows cluster1-worker
```

### Ashutosh
```bash
ssh ashutosh@<clusterwork public IP>          # password: Ashutosh_Pass!2026
kubectl get nodes                             # -> sees cluster2-cp + cluster2-worker
kubectl create deployment api --image=nginx --replicas=2
kubectl get pods -o wide                       # NODE column shows cluster2-worker
```

Watch the **HAProxy stats page** (`:8404/stats`) while they work — session
counts tick up on `cluster1_backend` for Manohar and `cluster2_backend` for
Ashutosh.

### Prove the isolation
While logged in as **manohar** on the bastion, try to reach cluster 2:
```bash
kubectl --server=https://<HAPROXY_IP>:7002 --insecure-skip-tls-verify get nodes
```
You get **`Unauthorized`** — Manohar's certificate is signed by cluster 1's CA,
which cluster 2 does not trust. Ashutosh gets the same result trying `:7001`.
That is the per-user, per-cluster isolation you asked for.

---

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| `kubectl get nodes` hangs from the bastion | Check HAProxy stats: is the backend UP? Is `HAPROXY_IP` in the kubeconfig correct? |
| TLS error "certificate is valid for ... not `<haproxy ip>`" | You forgot `--apiserver-cert-extra-sans=<HAPROXY_IP>` at `kubeadm init`. Re-run step 3/4 or regenerate the API server cert. |
| Worker stays `NotReady` | CNI not applied, or join ran before Flannel. Re-apply Flannel on the control plane. |
| `manohar` cannot SSH | Password auth disabled — re-run `06-clusterwork.sh`; it forces `PasswordAuthentication yes`. |
| Join token expired | On the control plane: `kubeadm token create --print-join-command`. |
| Control-plane init fails on CPU | Script already passes `--ignore-preflight-errors=NumCPU`; use `Standard_B2s` (2 vCPU) as in `01-create-vms.sh`. |

---

## 6. Clean up (stop paying)
```bash
bash scripts/99-cleanup.sh      # deletes the whole resource group
```

---

## 7. File map

```
k8s-haproxy-lab/
├── README.md                      <- this file
├── env.sh.example                 <- copy to env.sh, fill in IPs
├── haproxy/
│   └── haproxy.cfg                <- 2 frontends: :7001 cluster1, :7002 cluster2
├── rbac/
│   └── optional-namespace-admin.yaml   <- teaching alt to cluster-admin
└── scripts/
    ├── 01-create-vms.sh           <- laptop: make 6 password-based Azure VMs
    ├── 02-node-common.sh          <- each k8s node: containerd + kubeadm
    ├── 03-haproxy.sh              <- haproxy-vm: install + configure HAProxy
    ├── 04-init-cluster.sh         <- each control plane: kubeadm init + Flannel
    ├── 06-clusterwork.sh          <- bastion: kubectl + create manohar/ashutosh
    ├── 07-make-user.sh            <- control plane: user cert + RBAC + kubeconfig
    └── 99-cleanup.sh              <- laptop: delete everything
```

> Security note: the sample passwords in these scripts are for a throwaway lab.
> Change every password before using this anywhere real, and prefer SSH keys +
> short-lived certs in production.
