# Just-in-Time Prod Access on Kubernetes with 15-Minute Tokens

A demo of **short-lived, least-privilege access** to a production namespace on a self-managed Kubernetes cluster running on an Azure VM.

Instead of handing out a permanent kubeconfig, the cluster admin (the **CKS Guy**) issues a **ServiceAccount token that expires after 15 minutes**, scoped by RBAC to exactly what the requester needs.

| | |
|---|---|
| **Cluster** | Self-managed Kubernetes (kubeadm) on an Azure VM |
| **Target namespace** | `prod` |
| **Requester** | Me, working from my laptop |
| **Token lifetime** | 15 minutes (`kubectl create token --duration=15m`) |
| **Scenario 1** | List and scale pods/deployments, **no delete** |
| **Scenario 2** | Full permissions, **only inside `prod`** |

---

## How it works

```
 ┌────────────┐   1. Access request      ┌────────────────────┐
 │  Me        │ ───────────────────────► │  CKS Guy           │
 │  (laptop)  │                          │  (control-plane VM)│
 │            │   2. token + CA cert     │                    │
 │            │ ◄─────────────────────── │  SA + Role +       │
 │            │                          │  RoleBinding +     │
 │            │   3. kubectl (≤15 min)   │  kubectl create    │
 │            │ ───────────────────────► │  token --15m       │
 └────────────┘      Azure VM :6443      └────────────────────┘
                                            4. Token expires → 401
```

- Tokens come from the **TokenRequest API** (Kubernetes 1.24+). They are **not stored as Secrets**, so there is nothing long-lived to leak.
- Expiry is enforced by the API server. After 15 minutes the token is rejected with `Unauthorized`.
- RBAC (`Role` + `RoleBinding`) keeps the ServiceAccount confined to the `prod` namespace.

---

## Prerequisites

**CKS Guy (on the Azure VM)**
- `kubectl` with cluster-admin access on the control-plane node
- Azure **NSG inbound rule** allowing TCP `6443` from the requester's public IP only
- The API server certificate must include the VM's **public IP or DNS name** in its SANs (otherwise the laptop gets a TLS error; see Troubleshooting)

**Me (laptop)**
- `kubectl` installed (`kubectl version --client`)
- My public IP, to share with the CKS Guy (`curl ifconfig.me`)

---

## One-time demo setup (CKS Guy)

Create the `prod` namespace and a sample workload to work against.

```bash
kubectl create namespace prod
kubectl -n prod create deployment web --image=nginx --replicas=2
kubectl -n prod get pods
```

---

# Scenario 1: List and Scale, but No Delete

### The conversation

> **Me:** Hi, I've raised ticket **CHG-1042**. The `web` deployment in `prod` is slow and I need to check the pods and scale it up. I don't need to delete anything.
>
> **CKS Guy:** Got it. I'll give you view access to pods plus the ability to scale deployments. No delete, no exec, no secrets. The token is valid for 15 minutes. What's your public IP?
>
> **Me:** `203.0.113.25`
>
> **CKS Guy:** Allowing that on the NSG now. I'll send the CA cert and token over our secure channel. Don't paste the token into Slack or email.

### CKS Guy's steps

**1. Allow the requester's IP on the Azure NSG (port 6443)**

```bash
az network nsg rule create \
  --resource-group rg-k8s-prod \
  --nsg-name k8s-master-nsg \
  --name allow-jit-CHG-1042 \
  --priority 310 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes 203.0.113.25/32 \
  --destination-port-ranges 6443
```

**2. Create the ServiceAccount, Role and RoleBinding**

Save as `scenario1-scaler.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jit-scaler
  namespace: prod
  labels:
    access-ticket: CHG-1042
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-list-scale
  namespace: prod
rules:
  # View pods and their logs
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  # View deployments and replicasets
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  # Scale only (via the scale subresource). No delete verb anywhere.
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "replicasets/scale", "statefulsets/scale"]
    verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jit-scaler-binding
  namespace: prod
subjects:
  - kind: ServiceAccount
    name: jit-scaler
    namespace: prod
roleRef:
  kind: Role
  name: pod-list-scale
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f scenario1-scaler.yaml
```

**3. Verify the permissions before handing anything over**

```bash
SA=system:serviceaccount:prod:jit-scaler
kubectl auth can-i list pods                     -n prod --as=$SA   # yes
kubectl auth can-i patch deployments/scale       -n prod --as=$SA   # yes
kubectl auth can-i delete pods                   -n prod --as=$SA   # no
kubectl auth can-i delete deployments            -n prod --as=$SA   # no
kubectl auth can-i list pods                     -n default --as=$SA # no
```

**4. Issue a 15-minute token**

```bash
kubectl -n prod create token jit-scaler --duration=15m > jit-scaler.token
```

**5. Collect the CA cert and API server address**

```bash
# CA certificate (kubeadm default location)
sudo cp /etc/kubernetes/pki/ca.crt ./ca.crt

# API server endpoint: use the VM's PUBLIC IP or DNS, not the private one
echo "https://<VM_PUBLIC_IP>:6443"
```

**6. Send `ca.crt`, the token and the endpoint to the requester over a secure channel.**

### My steps (laptop)

**1. Build a separate kubeconfig** so my normal config stays untouched:

```bash
export KUBECONFIG=~/.kube/prod-jit.config
TOKEN=$(cat jit-scaler.token)

kubectl config set-cluster azure-prod \
  --server=https://<VM_PUBLIC_IP>:6443 \
  --certificate-authority=./ca.crt \
  --embed-certs=true

kubectl config set-credentials jit-scaler --token="$TOKEN"

kubectl config set-context prod-jit \
  --cluster=azure-prod --user=jit-scaler --namespace=prod

kubectl config use-context prod-jit
```

**2. Do the work**

```bash
kubectl get pods
kubectl get deployments
kubectl logs deploy/web --tail=20

# Scale up
kubectl scale deployment web --replicas=5
kubectl get pods -w
```

**3. Confirm what I can't do**

```bash
kubectl delete pod <pod-name>
# Error from server (Forbidden): pods "<pod-name>" is forbidden:
# User "system:serviceaccount:prod:jit-scaler" cannot delete resource "pods" ...

kubectl get secrets        # Forbidden
kubectl get pods -n kube-system   # Forbidden
```

**4. After 15 minutes**

```bash
kubectl get pods
# error: You must be logged in to the server (Unauthorized)
```

> **Me:** Scaled `web` to 5 replicas, latency is back to normal. My token has expired now.
>
> **CKS Guy:** Thanks. Cleaning up the access and the NSG rule, and closing CHG-1042.

---

# Scenario 2: Full Permissions on the `prod` Namespace

### The conversation

> **Me:** New ticket, **CHG-1057**. A bad release went out. I need to delete broken pods, roll back the deployment, fix a ConfigMap and maybe exec into a container.
>
> **CKS Guy:** That's a bigger ask, so it needs approval from the service owner. *(approval received)* OK, you'll get full control of `prod` only. Nothing cluster-wide: no nodes, no other namespaces, no cluster roles. Still 15 minutes. If you need more time, ask and I'll mint a fresh token rather than extend this one.
>
> **Me:** Same IP as before, `203.0.113.25`.

### CKS Guy's steps

**1. NSG rule**: same as Scenario 1, with the rule named `allow-jit-CHG-1057`.

**2. Create the ServiceAccount and a namespace-scoped full-access Role**

Save as `scenario2-admin.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jit-prod-admin
  namespace: prod
  labels:
    access-ticket: CHG-1057
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prod-full-access
  namespace: prod
rules:
  # Everything, but a Role can only ever apply inside its own namespace
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jit-prod-admin-binding
  namespace: prod
subjects:
  - kind: ServiceAccount
    name: jit-prod-admin
    namespace: prod
roleRef:
  kind: Role
  name: prod-full-access
  apiGroup: rbac.authorization.k8s.io
```

> **Alternative:** bind the built-in `admin` ClusterRole with a **RoleBinding** (not a ClusterRoleBinding). It gives near-full namespace control but excludes editing ResourceQuotas and the namespace itself, which is often the safer choice.
> ```bash
> kubectl -n prod create rolebinding jit-prod-admin-binding \
>   --clusterrole=admin --serviceaccount=prod:jit-prod-admin
> ```

```bash
kubectl apply -f scenario2-admin.yaml
```

**3. Verify**

```bash
SA=system:serviceaccount:prod:jit-prod-admin
kubectl auth can-i '*' '*'          -n prod    --as=$SA   # yes
kubectl auth can-i delete pods      -n prod    --as=$SA   # yes
kubectl auth can-i create pods/exec -n prod    --as=$SA   # yes
kubectl auth can-i list pods        -n default --as=$SA   # no
kubectl auth can-i list nodes                  --as=$SA   # no
kubectl auth can-i create clusterrolebindings  --as=$SA   # no
```

**4. Issue the 15-minute token and send it with `ca.crt`**

```bash
kubectl -n prod create token jit-prod-admin --duration=15m > jit-prod-admin.token
```

### My steps (laptop)

**1. Point my JIT kubeconfig at the new token**

```bash
export KUBECONFIG=~/.kube/prod-jit.config
kubectl config set-credentials jit-prod-admin --token="$(cat jit-prod-admin.token)"
kubectl config set-context prod-jit-admin \
  --cluster=azure-prod --user=jit-prod-admin --namespace=prod
kubectl config use-context prod-jit-admin
```

**2. Fix the release**

```bash
kubectl get pods
kubectl delete pod <broken-pod>
kubectl rollout history deployment web
kubectl rollout undo deployment web
kubectl rollout status deployment web

kubectl edit configmap web-config
kubectl exec -it deploy/web -- sh
```

**3. Confirm the boundary still holds**

```bash
kubectl get pods -n kube-system   # Forbidden
kubectl get nodes                 # Forbidden
kubectl create namespace test     # Forbidden
```

**4. After 15 minutes the token stops working**

```bash
kubectl get pods
# error: You must be logged in to the server (Unauthorized)
```

> **Me:** Rolled back to revision 4 and fixed the ConfigMap. Pods are healthy. Access has expired.
>
> **CKS Guy:** Revoking everything now.

---

## Cleanup and revocation (CKS Guy)

A token can't be "un-issued", but deleting its ServiceAccount **invalidates it immediately**, even before the 15 minutes are up. Use this for early revocation too.

```bash
# Scenario 1
kubectl -n prod delete rolebinding jit-scaler-binding
kubectl -n prod delete role pod-list-scale
kubectl -n prod delete serviceaccount jit-scaler

# Scenario 2
kubectl -n prod delete rolebinding jit-prod-admin-binding
kubectl -n prod delete role prod-full-access
kubectl -n prod delete serviceaccount jit-prod-admin

# Close the network door
az network nsg rule delete -g rg-k8s-prod --nsg-name k8s-master-nsg -n allow-jit-CHG-1042
az network nsg rule delete -g rg-k8s-prod --nsg-name k8s-master-nsg -n allow-jit-CHG-1057
```

**Me (laptop):**

```bash
rm ~/.kube/prod-jit.config jit-*.token
unset KUBECONFIG
```

---

## Scenario comparison

| Action in `prod` | Scenario 1 (`jit-scaler`) | Scenario 2 (`jit-prod-admin`) |
|---|:---:|:---:|
| List / watch pods | ✅ | ✅ |
| View logs | ✅ | ✅ |
| Scale deployments | ✅ | ✅ |
| Delete pods / deployments | ❌ | ✅ |
| Exec into pods | ❌ | ✅ |
| Read Secrets | ❌ | ✅ |
| Edit ConfigMaps, rollback | ❌ | ✅ |
| Any other namespace | ❌ | ❌ |
| Nodes / cluster-scoped objects | ❌ | ❌ |
| Token lifetime | 15 min | 15 min |

---

## Troubleshooting

**`x509: certificate is valid for 10.0.0.4, not <public-ip>`**
The API server cert lacks the public IP. Either:
- Regenerate it with the public IP in the SANs (CKS Guy, on the control plane):
  ```bash
  sudo mv /etc/kubernetes/pki/apiserver.{crt,key} /tmp/
  sudo kubeadm init phase certs apiserver \
    --apiserver-cert-extra-sans=<VM_PUBLIC_IP>,<VM_DNS_NAME>
  # then restart the kube-apiserver static pod
  ```
- Or skip exposing 6443 and use an SSH tunnel, with `--server=https://127.0.0.1:6443` in the kubeconfig:
  ```bash
  ssh -L 6443:127.0.0.1:6443 azureuser@<VM_PUBLIC_IP>
  ```

**Connection timeout** — the NSG rule is missing, or your public IP changed. Check `curl ifconfig.me`.

**Token lasts longer than requested** — the API server may enforce a minimum or maximum via `--service-account-max-token-expiration`. The TokenRequest API minimum is 10 minutes, so 15 is fine. Check the real expiry by decoding the token's `exp` claim:
```bash
cut -d. -f2 jit-scaler.token | base64 -d 2>/dev/null | grep -o '"exp":[0-9]*'
```

**`Forbidden` on something you expected to work** — ask the CKS Guy to run `kubectl auth can-i --list -n prod --as=system:serviceaccount:prod:<sa>`.

---

## Good practices shown in this demo

- **Least privilege**: Scenario 1 uses the `scale` subresource so the requester can resize but never delete.
- **Namespace-bound**: only `Role` + `RoleBinding`, never `ClusterRoleBinding`.
- **Short-lived credentials**: 15-minute bound tokens instead of static Secrets or client certs.
- **Network scoping**: NSG opens 6443 only to one IP, only for the duration of the ticket.
- **Traceability**: resources are labelled with the ticket ID. Enable API server audit logging to record every action taken by `system:serviceaccount:prod:jit-*`.
- **Fast revocation**: deleting the ServiceAccount kills the token instantly.
