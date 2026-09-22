# 🎮 Gateway API Games Demo — Host-Based Routing on Kubernetes + Azure DNS

Two tiny web games, one Kubernetes **Gateway**, one public IP. The
[Kubernetes Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
routes purely on the **Host header**:

| You open in a browser                       | You get                    |
| ------------------------------------------- | -------------------------- |
| `http://tiktaktoc.akblazeacademy.com`       | ✖️⭕ **Tic-Tac-Toe** (with an unbeatable minimax AI) |
| `http://rps.akblazeacademy.com`             | ✊✋✌️ **Rock Paper Scissors** |

Both hostnames resolve — via **Azure DNS** — to the *same* Gateway public IP.
The Gateway inspects the hostname and forwards to the correct backend Service.

```
                    Azure DNS zone: akblazeacademy.com
       tiktaktoc  A  ->  <GATEWAY_PUBLIC_IP>  <-  A  rps
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │   Gateway (class nginx) │   1 public IP, port 80
                    │  listener: tiktaktoc…   │
                    │  listener: rps…         │
                    └───────────┬─────────────┘
              Host: tiktaktoc…  │  Host: rps…
                    ┌───────────┴───────────┐
                    ▼                       ▼
            HTTPRoute tictactoe      HTTPRoute rps
                    │                       │
            Service/Deploy           Service/Deploy
             tictactoe                    rps
           (nginx + ConfigMap)      (nginx + ConfigMap)
```

---

## 📁 Repository layout

```
gateway-games-demo/
├── README.md
├── games/
│   ├── tictactoe.html          # source game (edit here)
│   └── rps.html                # source game (edit here)
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-gateway.yaml         # Gateway with 2 hostname listeners
│   ├── 20-tictactoe-configmap.yaml   # generated from games/tictactoe.html
│   ├── 21-rps-configmap.yaml         # generated from games/rps.html
│   ├── 30-tictactoe.yaml       # Deployment + Service
│   ├── 31-rps.yaml             # Deployment + Service
│   ├── 40-httproutes.yaml      # 2 HTTPRoutes (host -> service)
│   └── kustomization.yaml
└── scripts/
    └── build-configmaps.sh     # regenerate ConfigMaps after editing HTML
```

---

## ✅ Prerequisites

- A Kubernetes cluster (this guide uses **AKS**, but any cluster works).
- `kubectl` **v1.29+** and, for AKS, the `az` CLI logged in (`az login`).
- Your **Azure DNS zone `akblazeacademy.com` already delegated** (you said this
  is done — i.e. your registrar's nameservers point at the Azure zone's NS records).
- Permission to create Kubernetes resources and Azure DNS record sets.

> **Why these two exact hostnames?** The Gateway listeners and HTTPRoutes are
> hard-wired to `tiktaktoc.akblazeacademy.com` and `rps.akblazeacademy.com`. If
> you use different names, search-and-replace them in `manifests/10-gateway.yaml`
> and `manifests/40-httproutes.yaml`.

---

## 1️⃣ (Optional) Create an AKS cluster

Skip if you already have a cluster.

```bash
az group create --name akblaze-rg --location eastus

az aks create \
  --resource-group akblaze-rg \
  --name akblaze-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys

az aks get-credentials --resource-group akblaze-rg --name akblaze-aks
kubectl get nodes    # should list Ready nodes
```

---

## 2️⃣ Install the Gateway API CRDs

The Gateway API kinds (`GatewayClass`, `Gateway`, `HTTPRoute`) are **not** built
into Kubernetes — you install them as CRDs first. (NGINX Gateway Fabric can also
install them for you; installing explicitly makes the version obvious.)

```bash
# v1.6.1 is what the current NGINX Gateway Fabric (2.7.x) ships against.
# Bump this to match your controller's supported Gateway API version if needed.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# verify
kubectl get crd | grep gateway.networking.k8s.io
```

You should see `gateways`, `gatewayclasses`, `httproutes`, and more.

---

## 3️⃣ Install a Gateway controller (NGINX Gateway Fabric)

The Gateway API is just an API — you need an implementation that actually
provisions a load balancer and proxies traffic. This demo targets
**NGINX Gateway Fabric**, which creates a `GatewayClass` named `nginx`.

```bash
# Install NGINX Gateway Fabric via its Helm chart (OCI registry)
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --create-namespace -n nginx-gateway

# Confirm the controller is running and the GatewayClass exists
kubectl get pods -n nginx-gateway
kubectl get gatewayclass          # 'nginx' should show ACCEPTED=True
```

> **Using something else?** Any conformant controller works — Istio, Envoy
> Gateway, Cilium, or **Azure Application Gateway for Containers (ALB)**. Just
> install it, note the GatewayClass name it creates, and set
> `spec.gatewayClassName` in `manifests/10-gateway.yaml` accordingly.

---

## 4️⃣ Deploy the games and the Gateway

```bash
# from the repo root
kubectl apply -k manifests/
#   ...or:  kubectl apply -f manifests/

# watch everything come up
kubectl get pods,svc,gateway,httproute -n games
```

Wait until:
- both `tictactoe` and `rps` pods are `Running`,
- the Gateway shows `PROGRAMMED=True`,
- both HTTPRoutes are `Accepted`.

```bash
kubectl get gateway games-gateway -n games \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

---

## 5️⃣ Get the Gateway's public IP

NGINX Gateway Fabric exposes the Gateway through a `LoadBalancer` Service.
Azure assigns it a public IP (this can take 1–3 minutes).

```bash
kubectl get svc -n nginx-gateway

# grab just the external IP of the nginx-gateway-fabric LoadBalancer service:
GATEWAY_IP=$(kubectl get svc -n nginx-gateway \
  -l app.kubernetes.io/name=nginx-gateway-fabric \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Gateway public IP: $GATEWAY_IP"
```

If `GATEWAY_IP` is empty, the LoadBalancer is still provisioning — re-run in a
minute, or find the right service name with `kubectl get svc -A | grep LoadBalancer`.

> The Gateway resource also reports its address:
> `kubectl get gateway games-gateway -n games -o jsonpath='{.status.addresses[0].value}'`

---

## 6️⃣ Point Azure DNS at the Gateway

Now create two **A records** in your existing Azure DNS zone, both pointing at
`$GATEWAY_IP`. Because your zone is already delegated, these names go live on the
public internet as soon as they propagate.

```bash
RG=akblaze-rg                    # resource group that holds the DNS zone
ZONE=akblazeacademy.com

# tiktaktoc.akblazeacademy.com  ->  Gateway IP
az network dns record-set a add-record \
  --resource-group "$RG" \
  --zone-name "$ZONE" \
  --record-set-name tiktaktoc \
  --ipv4-address "$GATEWAY_IP"

# rps.akblazeacademy.com  ->  Gateway IP
az network dns record-set a add-record \
  --resource-group "$RG" \
  --zone-name "$ZONE" \
  --record-set-name rps \
  --ipv4-address "$GATEWAY_IP"

# (optional) shorten the TTL so changes propagate fast during testing
az network dns record-set a update -g "$RG" -z "$ZONE" -n tiktaktoc --set ttl=60
az network dns record-set a update -g "$RG" -z "$ZONE" -n rps       --set ttl=60
```

Verify the records exist in the zone:

```bash
az network dns record-set a list -g "$RG" -z "$ZONE" -o table
```

> **Record-set name is relative to the zone.** `--record-set-name tiktaktoc`
> inside zone `akblazeacademy.com` produces the FQDN
> `tiktaktoc.akblazeacademy.com`. Do **not** put the full domain in the name.

---

## 7️⃣ Verify DNS resolves

```bash
nslookup tiktaktoc.akblazeacademy.com
nslookup rps.akblazeacademy.com
# both should return $GATEWAY_IP
```

Public DNS may take a few minutes. To test the routing *before* DNS propagates,
send the Host header directly to the IP:

```bash
curl -s -H "Host: tiktaktoc.akblazeacademy.com" http://$GATEWAY_IP/ | grep -o '<title>.*</title>'
curl -s -H "Host: rps.akblazeacademy.com"       http://$GATEWAY_IP/ | grep -o '<title>.*</title>'
```

You should see the two different `<title>` tags — proof that one IP is serving
both games based only on the hostname.

---

## 8️⃣ Play 🎉

Open in a browser:

- **http://tiktaktoc.akblazeacademy.com** → Tic-Tac-Toe (try "You vs Computer" — the AI never loses)
- **http://rps.akblazeacademy.com** → Rock Paper Scissors

Each page shows the hostname it was served on in the footer, so you can see the
routing at a glance.

---

## 🔁 Editing a game

The HTML lives in `games/`. The running pods serve it from a ConfigMap, so after
editing, regenerate the ConfigMaps and re-apply:

```bash
# 1. edit games/tictactoe.html or games/rps.html
# 2. regenerate the ConfigMap manifests
./scripts/build-configmaps.sh
# 3. apply and restart so pods pick up the new content
kubectl apply -f manifests/20-tictactoe-configmap.yaml -f manifests/21-rps-configmap.yaml
kubectl rollout restart deployment/tictactoe deployment/rps -n games
```

---

## 🔐 Add HTTPS (optional next step)

This demo is HTTP-only for simplicity. To serve `https://`:

1. Install **cert-manager** and create a `ClusterIssuer` (Let's Encrypt), or bring
   your own TLS cert as a Kubernetes `Secret`.
2. Add an `HTTPS` listener (port 443) with a `tls` block referencing that Secret to
   `manifests/10-gateway.yaml`.
3. Optionally add a redirect HTTPRoute from `:80` to `:443`.

See the [Gateway API TLS guide](https://gateway-api.sigs.k8s.io/guides/tls/).

---

## 🧹 Cleanup

```bash
# app + gateway
kubectl delete -k manifests/

# DNS records
az network dns record-set a delete -g "$RG" -z "$ZONE" -n tiktaktoc -y
az network dns record-set a delete -g "$RG" -z "$ZONE" -n rps       -y

# controller + CRDs (optional)
helm uninstall ngf -n nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# whole cluster (if you created it just for this)
az aks delete --resource-group akblaze-rg --name akblaze-aks --yes --no-wait
```

---

## 🩺 Troubleshooting

| Symptom | Check |
| --- | --- |
| Gateway `PROGRAMMED=False` | `kubectl describe gateway games-gateway -n games` — controller installed? GatewayClass name correct? |
| HTTPRoute not `Accepted` | `kubectl describe httproute tictactoe-route -n games` — `sectionName` must match a listener name in the Gateway. |
| No external IP on the LB Service | Azure still provisioning; wait, then `kubectl get svc -n nginx-gateway`. Check `kubectl get events -n nginx-gateway`. |
| `curl` with Host header works but the domain doesn't | DNS not propagated yet, or A record points at the wrong IP. Re-check step 6/7. |
| Browser shows the wrong game | Two A records point at the same IP but a listener/route hostname is misspelled. Confirm the exact spelling `tiktaktoc` (as requested) in gateway + route + DNS. |
| 404 / default nginx page | ConfigMap not mounted or empty. `kubectl get cm -n games`, then `kubectl describe pod -n games`. |

---

**Stack:** Kubernetes Gateway API `v1` · NGINX Gateway Fabric (`gatewayClassName: nginx`) · Azure DNS · nginx-unprivileged serving static HTML from ConfigMaps.
