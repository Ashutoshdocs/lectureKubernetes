# AKS + NGINX Ingress + cert-manager (Let's Encrypt) — Path-Based Routing with HTTPS

This project deploys **two simple web apps** on **Azure Kubernetes Service (AKS)** and exposes them on a single domain over **HTTPS**, using path-based routing:

| URL | Routed to |
|-----|-----------|
| `https://akblazeacademy.net/app1` | `app1-service` → app1 pods → "Welcome to APP1" |
| `https://akblazeacademy.net/app2` | `app2-service` → app2 pods → "Welcome to APP2" |

SSL certificates are issued **automatically and for free** by Let's Encrypt via cert-manager, and renewed before they expire.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Concepts — What Each Piece Is](#2-concepts--what-each-piece-is)
3. [Project Files](#3-project-files)
4. [Prerequisites](#4-prerequisites)
5. [Step-by-Step Setup](#5-step-by-step-setup)
6. [Verification & Troubleshooting](#6-verification--troubleshooting)
7. [Cleanup](#7-cleanup)

---

## 1. Architecture

```
                        Internet (user browser)
                                 │
                 https://akblazeacademy.net/app1
                                 │
                     DNS A record → Public IP
                                 │
                ┌────────────────▼────────────────┐
                │   Azure Load Balancer (Public)  │
                └────────────────┬────────────────┘
                                 │
  ┌──────────────────────────────▼───────────────────────────────┐
  │ AKS Cluster                                                  │
  │                                                              │
  │   ┌──────────────────────────────────────────┐               │
  │   │ NGINX Ingress Controller                 │◄── TLS cert   │
  │   │ (reads Ingress rules, terminates HTTPS)  │   (Secret:    │
  │   └───────────┬──────────────────┬───────────┘  aks-demo-tls)│
  │        /app1  │                  │  /app2           ▲        │
  │   ┌───────────▼──────┐  ┌────────▼─────────┐        │        │
  │   │ app1-service     │  │ app2-service     │  ┌─────┴──────┐ │
  │   │ ClusterIP :80    │  │ ClusterIP :80    │  │cert-manager│ │
  │   └───────────┬──────┘  └────────┬─────────┘  │ + Cluster- │ │
  │        ┌──────┴──────┐    ┌──────┴──────┐     │   Issuer   │ │
  │        │ app1 pod x2 │    │ app2 pod x2 │     └─────┬──────┘ │
  │        │   :5678     │    │   :5678     │           │        │
  │        └─────────────┘    └─────────────┘           │        │
  └─────────────────────────────────────────────────────┼────────┘
                                                        │
                                          Let's Encrypt (ACME server)
```

**Request flow:** Browser → DNS resolves domain to the Load Balancer IP → NGINX Ingress Controller decrypts HTTPS and checks the path → forwards to the right Service → Service load-balances across the app's pods.

---

## 2. Concepts — What Each Piece Is

### AKS (Azure Kubernetes Service)
A managed Kubernetes cluster on Azure. Azure runs the control plane for you; you only manage the worker nodes (VMs) where your pods run.

### Deployment
Tells Kubernetes *what to run* and *how many copies*. Here each app runs **2 replicas** of the `hashicorp/http-echo` image — a tiny web server that replies with a fixed text on port `5678`. If a pod dies, the Deployment recreates it.

### Service (ClusterIP)
Pods get new IPs every time they restart, so you never talk to them directly. A **Service** gives a stable name and IP (e.g. `app1-service`) and load-balances across all pods matching its `selector` (`app: app1`).
- `port: 80` → the port the Service listens on
- `targetPort: 5678` → the port on the container
- `ClusterIP` → reachable **only inside** the cluster (the Ingress exposes it externally)

### Ingress Controller (NGINX)
A reverse proxy running inside the cluster, exposed to the internet through **one** Azure public Load Balancer IP. It watches for Ingress resources and configures itself to route traffic. Without a controller, Ingress resources do nothing.

### Ingress (resource)
A set of **routing rules**: "for host `akblazeacademy.net`, send `/app1` to `app1-service` and `/app2` to `app2-service`." It also declares which TLS certificate to use. One public IP can serve many apps this way, instead of one Load Balancer per app.

### cert-manager
A Kubernetes add-on that automates TLS certificates: it requests them, proves you own the domain, stores them as Secrets, and renews them (Let's Encrypt certs last 90 days; cert-manager renews ~30 days before expiry).

### ClusterIssuer
A cluster-wide cert-manager resource that defines **where and how** to get certificates — here, Let's Encrypt production, using the **HTTP-01 challenge**.

### HTTP-01 Challenge (how domain ownership is proved)
1. cert-manager asks Let's Encrypt for a certificate for `akblazeacademy.net`.
2. Let's Encrypt replies with a token and says: "serve this at `http://akblazeacademy.net/.well-known/acme-challenge/<token>`."
3. cert-manager creates a temporary pod + Ingress rule to serve that token.
4. Let's Encrypt fetches the URL over the internet. If it gets the token → domain verified → certificate issued.
5. The certificate is saved in the Secret `aks-demo-tls`, and NGINX uses it for HTTPS.

> This is why **DNS must already point to the Ingress IP** and **port 80 must be reachable** before the certificate can be issued.

### cert-manager resources you'll see
When the Ingress is created, cert-manager creates a chain of resources automatically:

```
Ingress (annotation) → Certificate → CertificateRequest → Order → Challenge → Secret (aks-demo-tls)
```

---

## 3. Project Files

| File | What it does |
|------|--------------|
| `deployment-app1.yaml` | Runs 2 pods of http-echo replying "Welcome to APP1" |
| `deployment-app2.yaml` | Runs 2 pods of http-echo replying "Welcome to APP2" |
| `app1-service.yaml` | ClusterIP Service: port 80 → app1 pods on 5678 |
| `app2-service.yaml` | ClusterIP Service: port 80 → app2 pods on 5678 |
| `clusterissuer.yaml` | Let's Encrypt production issuer with HTTP-01 solver via NGINX |
| `ingress.yaml` | Host + path routing rules, TLS config, cert-manager annotation, HTTP→HTTPS redirect |

### Key fields in `ingress.yaml`

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod   # must match ClusterIssuer name
  nginx.ingress.kubernetes.io/ssl-redirect: "true"   # force HTTP → HTTPS
spec:
  ingressClassName: nginx                            # handled by NGINX controller
  tls:
  - hosts: [akblazeacademy.net]
    secretName: aks-demo-tls                         # cert-manager creates this Secret
```

---

## 4. Prerequisites

- An **Azure subscription**
- **Azure CLI** (`az`) installed and logged in: `az login`
- **kubectl** installed (`az aks install-cli` installs it)
- A **domain name** you control (here `akblazeacademy.net`) with access to its DNS settings
- A valid **email address** for Let's Encrypt notifications

> The commands below use **PowerShell** variable syntax (`$RG="..."`). In Bash, use `RG="AKSIngressRG"` (no `$` when assigning).

---

## 5. Step-by-Step Setup

### Step 1 — Create the Azure infrastructure

```powershell
$RG="AKSIngressRG"
$LOCATION="centralus"
$AKSNAME="AKSIngressDemo"

# Resource group (a logical container for Azure resources)
az group create --name $RG --location $LOCATION

# AKS cluster: 2 nodes, Azure CNI networking, managed identity
az aks create `
  --resource-group $RG `
  --name $AKSNAME `
  --node-count 2 `
  --node-vm-size Standard_B2s `
  --generate-ssh-keys `
  --network-plugin azure `
  --enable-managed-identity

# Download cluster credentials so kubectl talks to this cluster
az aks get-credentials --resource-group $RG --name $AKSNAME --overwrite-existing

# Confirm the nodes are Ready
kubectl get nodes
```

Cluster creation takes roughly 5–10 minutes.

### Step 2 — Deploy the apps and their Services

```bash
kubectl apply -f deployment-app1.yaml
kubectl apply -f deployment-app2.yaml
kubectl apply -f app1-service.yaml
kubectl apply -f app2-service.yaml

kubectl get pods      # expect 4 pods Running (2 per app)
kubectl get svc       # expect app1-service and app2-service (ClusterIP)
```

### Step 3 — Test the Services from inside the cluster

ClusterIP Services aren't reachable from your laptop, so start a temporary pod inside the cluster:

```bash
kubectl run test --rm -it --image=busybox -- sh
```

Inside the pod's shell:

```sh
wget -qO- http://app1-service    # → Welcome to APP1
wget -qO- http://app2-service    # → Welcome to APP2
exit
```

`--rm` deletes the test pod when you exit. If this works, the Deployments and Services are wired correctly.

### Step 4 — Install the NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
```

This creates the `ingress-nginx` namespace, the controller pods, and a Service of type `LoadBalancer` — which makes Azure provision a **public IP**.

Wait for the controller to be ready and the external IP to appear:

```bash
kubectl get pods -n ingress-nginx
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
ingress-nginx-controller   LoadBalancer   10.0.x.x      20.xx.xx.xx     80:xxxxx/TCP,443:xxxxx/TCP
```

Copy the **EXTERNAL-IP** (it may show `<pending>` for a minute or two).

> Install the controller **once**. The original command notes list this step twice; running it again is harmless but unnecessary.

### Step 5 — Point your domain to the Ingress IP (DNS)

At your DNS provider (Azure DNS, GoDaddy, Cloudflare, etc.) create an **A record**:

| Type | Name / Host | Value | TTL |
|------|-------------|-------|-----|
| A | `@` (root, i.e. `akblazeacademy.net`) | `<EXTERNAL-IP from Step 4>` | 300 |

> If you use Cloudflare, set the record to **DNS only** (grey cloud) so Let's Encrypt can reach your cluster directly during the challenge.

Verify it has propagated before continuing:

```bash
nslookup akblazeacademy.net
```

The answer must show your Ingress EXTERNAL-IP. **Don't proceed until it does** — the certificate challenge will fail otherwise.

### Step 6 — Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

- The first command installs the **CRDs** (Custom Resource Definitions) — it teaches Kubernetes new object types like `ClusterIssuer`, `Certificate`, `Challenge`.
- The second installs the cert-manager controllers in the `cert-manager` namespace. (It also contains the CRDs, so the first command is a harmless duplicate.)

Wait until all three pods are Running:

```bash
kubectl get pods -n cert-manager
# cert-manager, cert-manager-cainjector, cert-manager-webhook → Running
```

> Applying the ClusterIssuer before the **webhook** pod is ready causes an error like `failed calling webhook`. Just wait ~1 minute and retry.

### Step 7 — Create the ClusterIssuer

Edit `clusterissuer.yaml` and set **your** email:

```yaml
email: you@yourdomain.com
```

Then apply it:

```bash
kubectl apply -f clusterissuer.yaml
kubectl get clusterissuer
# NAME               READY
# letsencrypt-prod   True
```

> **Tip — avoid rate limits while testing:** Let's Encrypt production limits how many certs you can request per domain per week. While experimenting, create a second issuer named `letsencrypt-staging` using server `https://acme-staging-v02.api.letsencrypt.org/directory` and point the Ingress annotation at it. Staging certs aren't browser-trusted, but they confirm the whole flow works. Switch back to `letsencrypt-prod` when ready.

### Step 8 — Create the Ingress

If you're using your own domain, replace `akblazeacademy.net` in both `tls.hosts` and `rules.host`. Then:

```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

```
NAME           CLASS   HOSTS                ADDRESS       PORTS     AGE
demo-ingress   nginx   akblazeacademy.net   20.xx.xx.xx   80, 443   30s
```

Applying the Ingress does two things at once:
1. NGINX starts routing `/app1` and `/app2`.
2. cert-manager sees the `cert-manager.io/cluster-issuer` annotation and starts requesting the certificate.

### Step 9 — Watch the certificate get issued

```bash
kubectl get certificate
```

```
NAME           READY   SECRET         AGE
aks-demo-tls   True    aks-demo-tls   2m
```

`READY = True` usually takes 1–3 minutes. Then open:

- https://akblazeacademy.net/app1 → **Welcome to APP1**
- https://akblazeacademy.net/app2 → **Welcome to APP2**

The browser should show a valid padlock, and plain `http://` requests should redirect to `https://`.

---

## 6. Verification & Troubleshooting

### Useful commands

| Command | What to look for |
|---------|------------------|
| `kubectl get pods` | All app pods `Running` |
| `kubectl get svc` | Services exist with correct ports |
| `kubectl get ingress` | `ADDRESS` populated with the public IP |
| `kubectl get certificate` | `READY = True` |
| `kubectl get certificaterequest` | `APPROVED = True`, `READY = True` |
| `kubectl get order` | `STATE = valid` |
| `kubectl get challenge` | Should disappear once successful; if stuck, it's the problem |
| `kubectl get secret` | `aks-demo-tls` of type `kubernetes.io/tls` exists |

To dig into anything stuck, use `kubectl describe`:

```bash
kubectl describe certificate aks-demo-tls
kubectl describe challenge
kubectl logs -n cert-manager deploy/cert-manager
```

### Common problems

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Certificate stuck at `READY False` | Challenge can't be reached | Check `kubectl describe challenge` for the exact error |
| Challenge error: connection refused / timeout | DNS not pointing to Ingress IP, or not yet propagated | Re-check Step 5 with `nslookup` |
| Challenge error: 404 | Wrong ingress class in ClusterIssuer | `solvers.http01.ingress.class` must be `nginx` |
| `failed calling webhook` on apply | cert-manager webhook not ready | Wait for cert-manager pods, retry |
| `EXTERNAL-IP <pending>` forever | Azure LB still provisioning or quota issue | Wait; check `kubectl describe svc -n ingress-nginx ingress-nginx-controller` |
| Browser says "Kubernetes Ingress Controller Fake Certificate" | Real cert not issued yet | Wait for `READY True`, or troubleshoot the challenge |
| `rateLimited` in order/challenge | Too many production requests | Use the staging issuer, wait for the limit to reset |
| 404 from NGINX on `/app1` | Host header doesn't match | Access via the domain, not the raw IP |

---

## 7. Cleanup

Delete everything (including the cluster, Load Balancer and public IP) to stop billing:

```bash
az group delete --name AKSIngressRG --yes --no-wait
```

AKS also creates a second resource group named `MC_AKSIngressRG_AKSIngressDemo_centralus` for its nodes and networking; it's removed automatically when the cluster is deleted.

Don't forget to remove the DNS A record afterwards.

---

## Quick Reference — Full Order of Operations

```
1. Create RG + AKS cluster, get credentials
2. Apply app Deployments + Services
3. Test internally with busybox
4. Install NGINX Ingress Controller → get EXTERNAL-IP
5. Create DNS A record → verify with nslookup
6. Install cert-manager → wait for pods
7. Apply ClusterIssuer (with your email)
8. Apply Ingress
9. Wait for Certificate READY → browse https://<domain>/app1 and /app2
```
