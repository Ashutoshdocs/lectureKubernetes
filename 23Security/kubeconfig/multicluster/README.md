# Kubernetes Multi-Cluster Kubeconfig / KubeContext Demo

## Execution Location Legend

- **LAPTOP** = your Windows/Linux/macOS machine where `kubectl` will manage both clusters.
- **VM-1** = Azure VM-1, Kubernetes control-plane node.
- **VM-2** = Azure VM-2, Kubernetes control-plane node.
- **AZURE PORTAL / AZURE CLI** = Azure networking/NSG operation.

**Rule of thumb:** certificate and Kubernetes server changes happen on the VM; `scp`, `kubectl --kubeconfig`, context switching, and merged kubeconfig operations happen on the laptop.


## Objective

Manage two isolated one-node Kubernetes clusters running on two separate Azure VMs from the same laptop.

Architecture:

Laptop
  |
  +-- context: cluster1 --> Azure VM-1 --> Kubernetes Cluster-1
  |
  +-- context: cluster2 --> Azure VM-2 --> Kubernetes Cluster-2

The clusters do NOT need network connectivity to each other.
The laptop needs network access to TCP 6443 on each VM.

---

# PART 1 — VM-1: Prepare Kubernetes API Server for Remote Access

**RUN ON: Azure VM-1 (Kubernetes control-plane VM)**

## 1. SSH to VM-1

**RUN ON: Laptop**

```bash
ssh azure@<VM1_PUBLIC_IP>
```

## 2. Become root

**RUN ON: Azure VM-1**

```bash
sudo -i
```

## 3. Create the script

**RUN ON: Azure VM-1**

```bash
nano /root/remote-k8s-access.sh
```

Paste the following:

```bash
#!/bin/bash

set -e

echo "================================================"
echo " Kubernetes Remote Access Fix Script"
echo "================================================"

read -p "Enter Azure VM Public IP: " PUBLIC_IP

PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "Detected Private IP : $PRIVATE_IP"
echo "Entered Public IP   : $PUBLIC_IP"
echo ""

mkdir -p /root/k8s-backup

echo "[1/8] Creating kubeadm configuration..."

cat > /root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration

apiServer:
  certSANs:
  - "${PUBLIC_IP}"
  - "${PRIVATE_IP}"
  - "127.0.0.1"
EOF

echo "[2/8] Backing up existing certificates..."

if [ -f /etc/kubernetes/pki/apiserver.crt ]; then
    cp /etc/kubernetes/pki/apiserver.crt \
    /root/k8s-backup/apiserver.crt.bak.$(date +%F-%H%M%S)
fi

if [ -f /etc/kubernetes/pki/apiserver.key ]; then
    cp /etc/kubernetes/pki/apiserver.key \
    /root/k8s-backup/apiserver.key.bak.$(date +%F-%H%M%S)
fi

echo "[3/8] Removing old API Server certificate..."

rm -f /etc/kubernetes/pki/apiserver.crt
rm -f /etc/kubernetes/pki/apiserver.key

echo "[4/8] Generating new API Server certificate..."

kubeadm init phase certs apiserver \
--config /root/kubeadm-config.yaml

echo "[5/8] Restarting kubelet..."

systemctl restart kubelet

echo "Waiting for control plane..."
sleep 30

echo "[6/8] Verifying SAN entries..."

openssl x509 \
-in /etc/kubernetes/pki/apiserver.crt \
-text \
-noout | grep -A2 "Subject Alternative Name"

echo ""

echo "[7/8] Creating kubeconfig for laptop..."

cp /etc/kubernetes/admin.conf /home/azure/admin.conf

sed -i "s#https://${PRIVATE_IP}:6443#https://${PUBLIC_IP}:6443#g" \
/home/azure/admin.conf

chown azure:azure /home/azure/admin.conf
chmod 600 /home/azure/admin.conf

echo ""

echo "[8/8] Cluster Health Check"

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl get nodes
kubectl get pods -A

echo ""
echo "================================================"
echo "SUCCESS"
echo "================================================"
echo ""
echo "Download file:"
echo "/home/azure/admin.conf"
echo ""
echo "From your laptop:"
echo "scp azure@${PUBLIC_IP}:/home/azure/admin.conf ./cluster1.yaml"
echo ""
```

Save:

```text
Ctrl + O
Enter
Ctrl + X
```

## 4. Make executable

**RUN ON: Azure VM-1**

```bash
chmod +x /root/remote-k8s-access.sh
```

## 5. Run

**RUN ON: Azure VM-1**

```bash
/root/remote-k8s-access.sh
```

When prompted:

```text
Enter Azure VM Public IP:
```

Enter:

```text
<VM1_PUBLIC_IP>
```

---

# PART 2 — VM-1: Verify Certificate

**RUN ON: Azure VM-1**

Check SAN:

```bash
openssl x509 \
-in /etc/kubernetes/pki/apiserver.crt \
-text \
-noout | grep -A2 "Subject Alternative Name"
```

You should see the VM public IP.

Example:

```text
X509v3 Subject Alternative Name:
    IP Address:20.50.10.25
    IP Address:10.0.1.4
    IP Address:127.0.0.1
```

Check Kubernetes:

```bash
kubectl get nodes
```

```bash
kubectl get pods -A
```

---

# PART 3 — Azure NSG

**RUN ON: Azure Portal / Azure CLI (from Laptop or any machine with Azure access)**

Allow TCP 6443 from your laptop's public IP.

Recommended:

```text
Protocol: TCP
Destination Port: 6443
Source: <YOUR_LAPTOP_PUBLIC_IP>/32
Action: Allow
```

Do NOT expose:

```text
0.0.0.0/0
```

in a real environment.

---

# PART 4 — Laptop: Test VM-1 API Server

**RUN ON: Laptop**

Linux/macOS:

```bash
nc -vz <VM1_PUBLIC_IP> 6443
```

Windows PowerShell:

```powershell
Test-NetConnection <VM1_PUBLIC_IP> -Port 6443
```

Expected:

```text
TcpTestSucceeded : True
```

---

# PART 5 — Laptop: Download VM-1 kubeconfig

**RUN ON: Laptop**

From your laptop:

```bash
mkdir kube-demo
cd kube-demo
```

Download:

```bash
scp azure@<VM1_PUBLIC_IP>:/home/azure/admin.conf ./cluster1.yaml
```

Check:

```bash
ls -l
```

You should have:

```text
cluster1.yaml
```

---

# PART 6 — Laptop: Check VM-1 kubeconfig

**RUN ON: Laptop**

Linux/macOS:

```bash
grep server cluster1.yaml
```

Windows PowerShell:

```powershell
Select-String "server" cluster1.yaml
```

Expected:

```text
server: https://<VM1_PUBLIC_IP>:6443
```

It should NOT point to the private IP if the laptop cannot reach that private IP.

---

# PART 7 — Laptop: Test VM-1

**RUN ON: Laptop**

```bash
kubectl --kubeconfig=./cluster1.yaml get nodes
```

```bash
kubectl --kubeconfig=./cluster1.yaml get pods -A
```

If both work, VM-1 is remotely accessible.

---

# PART 8 — VM-2: Repeat the Process

**RUN ON: Laptop for SSH/SCP; Azure VM-2 for Kubernetes/script commands**

SSH to VM-2 (**RUN ON: Laptop**):

```bash
ssh azure@<VM2_PUBLIC_IP>
```

Become root (**RUN ON: Azure VM-2**):

```bash
sudo -i
```

Create the same script (**RUN ON: Azure VM-2**):

```bash
nano /root/remote-k8s-access.sh
```

Paste the same script from PART 1.

Make executable (**RUN ON: Azure VM-2**):

```bash
chmod +x /root/remote-k8s-access.sh
```

Run (**RUN ON: Azure VM-2**):

```bash
/root/remote-k8s-access.sh
```

When prompted, enter (**on VM-2**):

```text
<VM2_PUBLIC_IP>
```

Verify (**RUN ON: Azure VM-2**):

```bash
kubectl get nodes
```

Download from your laptop (**RUN ON: Laptop**):

```bash
scp azure@<VM2_PUBLIC_IP>:/home/azure/admin.conf ./cluster2.yaml
```

Now your laptop directory should contain:

```text
kube-demo/
├── cluster1.yaml
└── cluster2.yaml
```

---

# PART 9 — Test Both Configurations Independently

**RUN ON: Laptop**

Test Cluster 1:

```bash
kubectl --kubeconfig=./cluster1.yaml get nodes
```

Test Cluster 2:

```bash
kubectl --kubeconfig=./cluster2.yaml get nodes
```

Also test:

```bash
kubectl --kubeconfig=./cluster1.yaml get pods -A
kubectl --kubeconfig=./cluster2.yaml get pods -A
```

---

# PART 10 — Rename Context in Cluster 1

**RUN ON: Laptop**

Check current context:

```bash
kubectl --kubeconfig=./cluster1.yaml config current-context
```

List contexts:

```bash
kubectl --kubeconfig=./cluster1.yaml config get-contexts
```

Usually kubeadm gives:

```text
kubernetes-admin@kubernetes
```

Rename:

```bash
kubectl --kubeconfig=./cluster1.yaml \
config rename-context \
kubernetes-admin@kubernetes \
cluster1
```

Verify (**RUN ON: Azure VM-2**):

```bash
kubectl --kubeconfig=./cluster1.yaml config get-contexts
```

---

# PART 11 — Rename Context in Cluster 2

**RUN ON: Laptop**

List:

```bash
kubectl --kubeconfig=./cluster2.yaml config get-contexts
```

Rename:

```bash
kubectl --kubeconfig=./cluster2.yaml \
config rename-context \
kubernetes-admin@kubernetes \
cluster2
```

Verify (**RUN ON: Azure VM-2**):

```bash
kubectl --kubeconfig=./cluster2.yaml config get-contexts
```

---

# PART 12 — Recommended: Rename Cluster Entries Too

**RUN ON: Laptop**

This avoids confusing duplicate cluster names when merging.

Cluster 1:

```bash
kubectl --kubeconfig=./cluster1.yaml \
config rename-cluster \
kubernetes \
cluster1
```

Cluster 2:

```bash
kubectl --kubeconfig=./cluster2.yaml \
config rename-cluster \
kubernetes \
cluster2
```

Verify (**RUN ON: Azure VM-2**):

```bash
kubectl --kubeconfig=./cluster1.yaml config view
```

```bash
kubectl --kubeconfig=./cluster2.yaml config view
```

---

# PART 13 — Merge Both Kubeconfigs

**RUN ON: Laptop**

## Linux/macOS

Run from the kube-demo directory:

```bash
export KUBECONFIG=$PWD/cluster1.yaml:$PWD/cluster2.yaml
```

Check:

```bash
kubectl config get-contexts
```

Expected:

```text
CURRENT   NAME
*         cluster1
          cluster2
```

## Windows PowerShell

```powershell
$env:KUBECONFIG="$PWD\cluster1.yaml;$PWD\cluster2.yaml"
```

Then:

```powershell
kubectl config get-contexts
```

---

# PART 14 — Test Context 1

**RUN ON: Laptop**

Switch:

```bash
kubectl config use-context cluster1
```

Check:

```bash
kubectl config current-context
```

Expected:

```text
cluster1
```

Get nodes:

```bash
kubectl get nodes
```

Get pods:

```bash
kubectl get pods -A
```

---

# PART 15 — Test Context 2

**RUN ON: Laptop**

Switch:

```bash
kubectl config use-context cluster2
```

Check:

```bash
kubectl config current-context
```

Expected:

```text
cluster2
```

Get nodes:

```bash
kubectl get nodes
```

Get pods:

```bash
kubectl get pods -A
```

---

# PART 16 — Strong Classroom Proof

**RUN ON: Laptop**

Create a unique namespace in Cluster 1:

```bash
kubectl config use-context cluster1
kubectl create namespace cluster1-demo
```

Verify (**RUN ON: Azure VM-2**):

```bash
kubectl get namespaces
```

Switch to Cluster 2:

```bash
kubectl config use-context cluster2
```

Check:

```bash
kubectl get namespaces
```

You should NOT see:

```text
cluster1-demo
```

Create a different namespace:

```bash
kubectl create namespace cluster2-demo
```

Now switch back:

```bash
kubectl config use-context cluster1
```

Check:

```bash
kubectl get namespaces
```

You should see:

```text
cluster1-demo
```

but not:

```text
cluster2-demo
```

This proves the contexts point to two different Kubernetes clusters.

---

# PART 17 — Create a Permanent Merged Config

**RUN ON: Laptop**

After testing:

```bash
KUBECONFIG=$PWD/cluster1.yaml:$PWD/cluster2.yaml \
kubectl config view --flatten > merged-config.yaml
```

Check:

```bash
kubectl --kubeconfig=./merged-config.yaml config get-contexts
```

Expected:

```text
CURRENT   NAME
*         cluster1
          cluster2
```

---

# PART 18 — Use merged-config.yaml

**RUN ON: Laptop**

Linux/macOS:

```bash
mkdir -p ~/.kube
cp merged-config.yaml ~/.kube/config
chmod 600 ~/.kube/config
```

Windows PowerShell:

```powershell
mkdir $HOME\.kube -Force
Copy-Item .\merged-config.yaml $HOME\.kube\config
```

Now simply:

```bash
kubectl config get-contexts
```

No `--kubeconfig` is required.

---

# PART 19 — Final Context Demo

**RUN ON: Laptop**

Show current context:

```bash
kubectl config current-context
```

Switch to Cluster 1:

```bash
kubectl config use-context cluster1
```

Run (**RUN ON: Azure VM-2**):

```bash
kubectl get nodes
kubectl get pods -A
```

Switch to Cluster 2:

```bash
kubectl config use-context cluster2
```

Run (**RUN ON: Azure VM-2**):

```bash
kubectl get nodes
kubectl get pods -A
```

---

# PART 20 — Useful Kubeconfig Commands

**RUN ON: Laptop**

Show all contexts:

```bash
kubectl config get-contexts
```

Show current context:

```bash
kubectl config current-context
```

Switch context:

```bash
kubectl config use-context cluster1
```

```bash
kubectl config use-context cluster2
```

Show complete configuration:

```bash
kubectl config view
```

Show configuration without certificate/key data:

```bash
kubectl config view --minify
```

Show the current context only:

```bash
kubectl config view --minify -o jsonpath='{.contexts[0].name}'
```

Show current API server:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
echo
```

---

# PART 21 — Troubleshooting

**RUN ON: Laptop unless explicitly marked VM**

## Check port 6443

Linux:

```bash
nc -vz <VM_PUBLIC_IP> 6443
```

Windows:

```powershell
Test-NetConnection <VM_PUBLIC_IP> -Port 6443
```

## Check API server on VM

```bash
ss -lntp | grep 6443
```

## Check API server Pod

```bash
kubectl get pods -n kube-system -o wide | grep kube-apiserver
```

## Check certificate SAN

```bash
openssl x509 \
-in /etc/kubernetes/pki/apiserver.crt \
-text \
-noout | grep -A2 "Subject Alternative Name"
```

## Check kubeconfig server

```bash
grep server cluster1.yaml
```

## Test directly with kubeconfig

```bash
kubectl --kubeconfig=cluster1.yaml cluster-info
```

```bash
kubectl --kubeconfig=cluster2.yaml cluster-info
```

## Verbose connection test

```bash
kubectl --kubeconfig=cluster1.yaml get nodes -v=6
```

---

# FINAL CONCEPT

One laptop:

```text
                    LAPTOP
                       |
                 ~/.kube/config
                       |
             +---------+---------+
             |                   |
        context: cluster1   context: cluster2
             |                   |
             v                   v
       Azure VM-1           Azure VM-2
       Public-IP:6443       Public-IP:6443
             |                   |
             v                   v
       K8s Cluster-1        K8s Cluster-2
```

Switch:

```bash
kubectl config use-context cluster1
```

Then:

```bash
kubectl get nodes
```

talks to Cluster 1.

Switch:

```bash
kubectl config use-context cluster2
```

Then:

```bash
kubectl get nodes
```

talks to Cluster 2.

KEY IDEA:

A kubeconfig can contain multiple clusters, users, and contexts.

A context determines which cluster and user kubectl uses.

The two Kubernetes clusters do not need to communicate with each other.
Only the laptop needs network access to each Kubernetes API server.
