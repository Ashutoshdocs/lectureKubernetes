# 🔒 Gateway API HTTPS Demo: Path Routing + Let's Encrypt (certbot) on Kubernetes + Azure DNS

Two working web apps and a landing page behind **one** Kubernetes Gateway, served over **HTTPS** with a free **Let's Encrypt** certificate issued by **certbot**:

| You open in a browser | You get |
| --- | --- |
| `https://akblazeacademy.net/` | 🏠 **Landing page** with links to both apps |
| `https://akblazeacademy.net/app1` | ✅ **TaskFlow**: to-do manager with priorities, filters, inline editing and a progress ring |
| `https://akblazeacademy.net/app2` | 💸 **Spendly**: income and expense tracker in ₹ with a category breakdown |
| `http://akblazeacademy.net/…` (any path) | ↪️ **301 redirect** to the same URL on `https://` |

Each page footer shows **which Pod served it** and a **🔒 HTTPS** badge, so you can see both the routing and the encryption at a glance.

```
                 Azure DNS zone: akblazeacademy.net
                 @ (apex)  A  ->  <GATEWAY_PUBLIC_IP>
                                  │
                                  ▼
           ┌───────────────────────────────────────────────┐
           │ Gateway  akblaze-gateway                      │
           │                                               │
           │  listener "http"  :80  ──► 301 to https://    │  (41-http-redirect.yaml)
           │  listener "https" :443 ──► TLS terminated     │  cert from Secret
           │                     │      here               │  "akblaze-tls"
           └─────────────────────┼─────────────────────────┘        ▲
                                 │ plain HTTP inside the cluster    │ loaded by
                   ┌─────────────┴──────────────┐                   │ scripts/load-cert-secret.sh
                   │ HTTPRoute akblaze-routes   │                   │
                   └──┬───────────┬──────────┬──┘          ┌────────┴────────┐
          /app1/...   │ /app2/... │          │ /           │ certbot (on your │
          rewrite → / │ rewrite → /          │             │ machine), DNS-01 │
                      ▼           ▼          ▼             │ via Azure DNS    │
                  Service app1 Service app2 Service home    └─────────────────┘
```

### How certbot proves you own the domain (DNS-01)

```
 your machine                         Azure DNS                     Let's Encrypt
 ────────────                         ─────────                     ─────────────
 certbot: "I want a cert for akblazeacademy.net" ──────────────────────────►
                                                        ◄── "put token T in a TXT record"
 auth hook: az ... txt add-record ──► _acme-challenge  TXT "T"
 hook waits until Azure's nameserver serves it
 certbot: "ready" ─────────────────────────────────────────────────────────►
                                      ◄──────────── LE looks up the TXT record, finds T
                                                        ◄── signed certificate
 cleanup hook: az ... txt remove-record
 load-cert-secret.sh ──► kubectl ──► Secret webapps/akblaze-tls ──► Gateway serves it
```

Because Let's Encrypt checks **DNS**, not your web server:

- you can issue the certificate **before** the cluster, Gateway, public IP or A record exist
- port 80 doesn't have to be reachable from the internet for validation
- **wildcard** certificates (`*.akblazeacademy.net`) work

---

## 📁 Repository layout

```
gateway-https-demo/
├── README.md
├── cert.env                       # ← your settings: email, domains, DNS zone, staging on/off
├── .gitignore                     # keeps .certbot/ (private keys) out of Git
├── apps/                          # page sources (edit here)
│   ├── home.html
│   ├── app1.html                  # TaskFlow
│   └── app2.html                  # Spendly
├── nginx/
│   └── default.conf               # shared nginx config: port 8080, /whoami, /healthz
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-gateway.yaml            # listeners: http :80 and https :443 (TLS)
│   ├── 20-nginx-conf-configmap.yaml   # generated
│   ├── 21-home-configmap.yaml         # generated
│   ├── 22-app1-configmap.yaml         # generated
│   ├── 23-app2-configmap.yaml         # generated
│   ├── 30-home.yaml               # Deployment + Service
│   ├── 31-app1.yaml               # Deployment + Service
│   ├── 32-app2.yaml               # Deployment + Service
│   ├── 40-httproute.yaml          # path routing, attached to the https listener
│   ├── 41-http-redirect.yaml      # http -> https 301, attached to the http listener
│   └── kustomization.yaml
└── scripts/
    ├── common.sh                  # shared settings (sourced by the others)
    ├── issue-cert.sh              # certbot: get the certificate, load it into the cluster
    ├── renew-cert.sh              # certbot: renew if due (cron this), then reload
    ├── load-cert-secret.sh        # cert files -> Kubernetes TLS Secret
    ├── cert-status.sh             # compare cert on disk vs Secret vs live Gateway
    ├── build-configmaps.sh        # regenerate ConfigMaps after editing apps/ or nginx/
    └── hooks/
        ├── azure-dns-auth.sh      # certbot hook: add the _acme-challenge TXT record
        └── azure-dns-cleanup.sh   # certbot hook: remove it afterwards
```

After the first run, certbot's data lives in `.certbot/` (account, private key, certificates, renewal settings). **Keep that folder private and never commit it.**

---

## ✅ Prerequisites

On the machine where you'll run certbot (your laptop, a jump box, or **Azure Cloud Shell**):

| Tool | Install |
| --- | --- |
| `az` CLI, logged in | `az login` |
| `kubectl` v1.29+ | pointed at your cluster |
| `helm` v3.8+ | for the Gateway controller |
| **certbot** 2.x or newer | Ubuntu: `sudo snap install --classic certbot` · macOS: `brew install certbot` · anywhere with Python: `pip install --user certbot` |
| `openssl` | usually preinstalled |
| `dig` (recommended) | Ubuntu: `sudo apt install dnsutils` · macOS: built in. Without it the hook waits a fixed 60 s instead of checking. |

On the Azure side:

- **Azure DNS zone `akblazeacademy.net` already delegated**: your registrar's nameservers must point at the zone's Azure nameservers.
  ```bash
  az network dns zone show -g akblaze-rg -n akblazeacademy.net --query nameServers -o tsv
  nslookup -type=NS akblazeacademy.net     # should list the same nameservers
  ```
- Your `az` identity needs **DNS Zone Contributor** on that zone, because the certbot hooks add and remove TXT records:
  ```bash
  ZONE_ID=$(az network dns zone show -g akblaze-rg -n akblazeacademy.net --query id -o tsv)
  az role assignment create --assignee "$(az ad signed-in-user show --query id -o tsv)" \
    --role "DNS Zone Contributor" --scope "$ZONE_ID"
  ```
  Owners and Contributors on the resource group already have this.

> **Windows?** Run everything from **WSL** or **Azure Cloud Shell** (Bash). Cloud Shell already has `az`, `kubectl`, `helm` and `dig`; install certbot there with `pip install --user certbot`.

---

## 1️⃣ (Optional) Create an AKS cluster

Skip this if you already have a cluster.

```bash
az group create --name akblaze-rg --location centralindia

az aks create \
  --resource-group akblaze-rg \
  --name akblaze-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys

az aks get-credentials --resource-group akblaze-rg --name akblaze-aks
kubectl get nodes
```

---

## 2️⃣ Install the Gateway API CRDs

```bash
# Match this version to what your Gateway controller supports.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

kubectl get crd | grep gateway.networking.k8s.io
```

---

## 3️⃣ Install the Gateway controller (NGINX Gateway Fabric)

```bash
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --create-namespace -n nginx-gateway

kubectl get pods -n nginx-gateway
kubectl get gatewayclass          # 'nginx' should show ACCEPTED=True
```

> Using Istio, Envoy Gateway, Cilium or **Azure Application Gateway for Containers** instead? Install it and set `spec.gatewayClassName` in `manifests/10-gateway.yaml` to its GatewayClass. HTTPS listeners, `RequestRedirect` and `URLRewrite` are supported by all of these.

---

## 4️⃣ Configure `cert.env`

Open `cert.env` and set at least your email:

```bash
CERT_EMAIL="you@yourdomain.com"          # expiry warnings go here
CERT_DOMAINS="akblazeacademy.net"        # comma-separated; first one names the cert
DNS_ZONE="akblazeacademy.net"
DNS_RG="akblaze-rg"                      # resource group of the DNS ZONE (not the cluster)
K8S_NAMESPACE="webapps"                  # must match the manifests
K8S_SECRET="akblaze-tls"                 # must match tls.certificateRefs in 10-gateway.yaml
STAGING=1                                # start with the staging CA
```

| Want | Set `CERT_DOMAINS` to |
| --- | --- |
| Just the apex (this demo) | `"akblazeacademy.net"` |
| Apex + www | `"akblazeacademy.net,www.akblazeacademy.net"` |
| Apex + every subdomain | `"akblazeacademy.net,*.akblazeacademy.net"` |

> **Why staging first?** Let's Encrypt production allows only **5 duplicate certificates per week** and limits failed validations. Staging has much higher limits and the same flow; its certificates just aren't trusted by browsers. Get everything working on staging, then switch.

---

## 5️⃣ Issue the certificate (staging) and load it into the cluster

```bash
./scripts/issue-cert.sh
```

What you'll see:

```
>> Using Let's Encrypt STAGING (test certificate, browsers will warn)
>> Requesting certificate 'akblazeacademy.net' for: akblazeacademy.net
Hook '--manual-auth-hook' for akblazeacademy.net ran with output:
 [auth] adding TXT _acme-challenge.akblazeacademy.net in zone akblazeacademy.net
 [auth] waiting for ns1-xx.azure-dns.com to serve the record
 [auth] record is live
Hook '--manual-cleanup-hook' for akblazeacademy.net ran with output:
 [cleanup] removing TXT _acme-challenge.akblazeacademy.net
Successfully received certificate.
>> Loading certificate into Kubernetes
secret/akblaze-tls created
Secret webapps/akblaze-tls now holds:
  DNS:akblazeacademy.net
  issuer=C = US, O = (STAGING) Let's Encrypt, CN = (STAGING) ...
  notAfter=...
```

It takes about 30–60 seconds, mostly waiting for Azure DNS. Confirm the Secret:

```bash
kubectl get secret akblaze-tls -n webapps
# NAME          TYPE                DATA   AGE
# akblaze-tls   kubernetes.io/tls   2      10s
```

> Want to watch the challenge happen? In a second terminal during step 5, run
> `watch -n 2 "az network dns record-set txt list -g akblaze-rg -z akblazeacademy.net -o table"`
> and you'll see `_acme-challenge` appear and disappear.

---

## 6️⃣ Deploy the apps, the Gateway and the routes

```bash
kubectl apply -k manifests/

kubectl get pods,svc,gateway,httproute -n webapps
kubectl wait --for=condition=Programmed gateway/akblaze-gateway -n webapps --timeout=180s
```

Check that **both** listeners are healthy, especially that the HTTPS listener found the certificate:

```bash
kubectl get gateway akblaze-gateway -n webapps \
  -o jsonpath='{range .status.listeners[*]}{.name}: {range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
# http: Accepted=True Programmed=True ResolvedRefs=True ...
# https: Accepted=True Programmed=True ResolvedRefs=True ...
```

If `https` shows `ResolvedRefs=False`, the Secret is missing or in the wrong namespace. Re-run step 5.

---

## 7️⃣ Get the public IP and test before DNS

```bash
GATEWAY_IP=$(kubectl get gateway akblaze-gateway -n webapps -o jsonpath='{.status.addresses[0].value}')
echo "$GATEWAY_IP"
```

`curl --resolve` pins the domain to the IP, so TLS (SNI) and routing both behave exactly as they will once DNS is live:

```bash
R="--resolve akblazeacademy.net:80:$GATEWAY_IP --resolve akblazeacademy.net:443:$GATEWAY_IP"

# HTTP redirects to HTTPS, keeping the path
curl -sI $R http://akblazeacademy.net/app1/ | grep -iE '^HTTP|^location'
# HTTP/1.1 301 Moved Permanently
# location: https://akblazeacademy.net/app1/

# HTTPS routing (-k because the staging cert isn't trusted yet)
for p in / /app1/ /app2/; do
  printf "%-8s " "$p"; curl -sk $R "https://akblazeacademy.net$p" | grep -o '<title>.*</title>'
done

# Which certificate is the Gateway serving?
echo | openssl s_client -connect "$GATEWAY_IP:443" -servername akblazeacademy.net 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

---

## 8️⃣ Point Azure DNS at the Gateway

One A record at the zone apex (`@`):

```bash
RG=akblaze-rg
ZONE=akblazeacademy.net

az network dns record-set a add-record -g "$RG" -z "$ZONE" -n "@" --ipv4-address "$GATEWAY_IP"
az network dns record-set a update     -g "$RG" -z "$ZONE" -n "@" --set ttl=300

nslookup akblazeacademy.net        # should return $GATEWAY_IP
```

> `@` means the zone itself. Don't put the full domain in `-n`; that creates `akblazeacademy.net.akblazeacademy.net`.

---

## 9️⃣ Switch to the real (production) certificate

Once staging works end to end, edit `cert.env`:

```bash
STAGING=0
```

and run the same script again:

```bash
./scripts/issue-cert.sh
# >> Using Let's Encrypt PRODUCTION
# >> Existing certificate is from staging; forcing a new production one
# ...
# secret/akblaze-tls configured
```

The script notices the staging certificate and forces a new one. It then **updates the Secret in place**. The Gateway watches the Secret and starts serving the new certificate within seconds, with **no restarts and no downtime**.

```bash
./scripts/cert-status.sh
# 1. On disk  ... issuer=C = US, O = Let's Encrypt, CN = E…
# 2. Secret   ... issuer=C = US, O = Let's Encrypt, CN = E…
# 3. Live     ... issuer=C = US, O = Let's Encrypt, CN = E…
```

All three should show the same serial and a non-staging issuer.

---

## 🔟 Open it 🎉

- **https://akblazeacademy.net/** shows the landing page with a 🔒 HTTPS badge in the footer
- **https://akblazeacademy.net/app1** opens TaskFlow
- **https://akblazeacademy.net/app2** opens Spendly
- **http://akblazeacademy.net/app2** lands on `https://…/app2` automatically

---

## 🔄 Renewal

Let's Encrypt certificates are short-lived (90 days by default), so renewal has to be automatic. certbot decides when a certificate is due, typically about 30 days before it expires, so running the renewal script daily is safe.

```bash
./scripts/renew-cert.sh            # renews only if due; otherwise does nothing
./scripts/renew-cert.sh --dry-run  # full rehearsal against staging: real DNS challenge, nothing saved
./scripts/renew-cert.sh --force    # renew right now (handy for demos)
```

`renew-cert.sh` reuses the DNS hooks saved by `issue-cert.sh`. After a successful renewal, certbot runs `load-cert-secret.sh` as its **deploy hook**, so the Secret, and therefore the Gateway, is updated automatically.

### Automate it with cron

```bash
crontab -e
```

```cron
# every day at 03:17, renew if due and reload the Gateway's certificate
17 3 * * * /full/path/to/gateway-https-demo/scripts/renew-cert.sh >> /full/path/to/gateway-https-demo/.certbot/renew.log 2>&1
```

The cron job needs a working `az` login and kubeconfig, so it should run as the user who ran `issue-cert.sh`.

> **Unattended machines:** interactive `az login` tokens eventually expire. For a server or CI job, log in with a service principal or managed identity that has **DNS Zone Contributor** on the zone (`az login --service-principal ...` or `az login --identity`) at the top of the cron command.

### 📈 Watch a renewal go live

Use two terminals.

**Terminal 1:** watch the certificate the Gateway is actually serving:

```bash
watch -n 2 -d "echo | openssl s_client -connect akblazeacademy.net:443 -servername akblazeacademy.net 2>/dev/null | openssl x509 -noout -serial -enddate"
```

**Terminal 2:** force a renewal:

```bash
./scripts/renew-cert.sh --force
```

When the deploy hook updates the Secret, Terminal 1 highlights a **new serial** and a **new expiry date**. Any browser tab you had open keeps working.

---

## 🔬 How it works

### Two listeners, two routes

| Listener | Port | Route attached | What happens |
| --- | --- | --- | --- |
| `http` | 80 | `akblaze-http-redirect` | Every request gets `301` to the same path on `https://` |
| `https` | 443 | `akblaze-routes` | TLS is decrypted with the `akblaze-tls` certificate, then path routing applies |

Each HTTPRoute uses `parentRefs[].sectionName` to choose its listener. The app route attaches **only** to `https`, so there is no way to reach an app over plain HTTP.

### TLS termination

`tls.mode: Terminate` means the Gateway decrypts traffic and talks to the Pods over plain HTTP inside the cluster. The apps need no certificates and no code changes; the same manifests serve HTTP or HTTPS depending only on the Gateway. Since there is one hostname, a single certificate covers every path (`/`, `/app1`, `/app2`, and any you add later).

### Path routing (unchanged from the HTTP version)

| Browser requests | Rule matched | Backend | Pod receives |
| --- | --- | --- | --- |
| `https://…/` | `/` | `home` | `/` |
| `https://…/app1` or `/app1/` | `/app1` | `app1` | `/` |
| `https://…/app1/whoami` | `/app1` | `app1` | `/whoami` |
| `https://…/app2/` | `/app2` | `app2` | `/` |
| `https://…/app10` | `/` | `home` | `/app10` (landing page) |

The longest matching prefix wins, prefixes match whole path segments, and the `URLRewrite` filter strips `/app1` or `/app2` so each app can be built as if it lived at `/`.

### What lives where

| Thing | Where | In Git? |
| --- | --- | --- |
| Gateway, routes, apps | `manifests/` | ✅ yes |
| certbot account, private key, certs, renewal config | `.certbot/` on the machine that ran certbot | ❌ never |
| Certificate + key the Gateway uses | Secret `webapps/akblaze-tls` in the cluster | ❌ never |
| `_acme-challenge` TXT record | Azure DNS, only during issuance or renewal | n/a |

---

## 🛡️ Hardening (optional)

- **Back up `.certbot/`** somewhere private (for example an Azure Key Vault secret or a private storage account). If it's lost, just run `issue-cert.sh` again to get a fresh certificate.
- **Restrict who can issue certificates** for your domain with a CAA record:
  ```bash
  az network dns record-set caa add-record -g akblaze-rg -z akblazeacademy.net -n "@" \
    --flags 0 --tag issue --value "letsencrypt.org"
  ```
- **HSTS** tells browsers to always use HTTPS. Add a `ResponseHeaderModifier` filter to the rules in `40-httproute.yaml` that sets `Strict-Transport-Security: max-age=300`. Start small and raise it only once you're sure HTTPS will stay.
- **Fully in-cluster automation:** once you're comfortable with the flow, **cert-manager** can do the same DNS-01 dance with Azure DNS from inside the cluster, with no workstation or cron involved. This demo uses certbot so every step stays visible.

---

## 🔁 Editing an app

```bash
# 1. edit apps/*.html or nginx/default.conf
./scripts/build-configmaps.sh
kubectl apply -k manifests/
kubectl rollout restart deployment/app1 deployment/app2 deployment/home -n webapps
```

To add an `/app3`, copy `apps/app1.html` and `manifests/31-app1.yaml`, add a `gen` line to `build-configmaps.sh`, and add a `/app3` rule to `40-httproute.yaml`. The existing certificate already covers it, so no certificate or DNS change is needed.

---

## 🧹 Cleanup

```bash
# apps, routes, Gateway (also releases the public IP)
kubectl delete -k manifests/
kubectl delete secret akblaze-tls -n webapps --ignore-not-found

# DNS record
az network dns record-set a delete -g akblaze-rg -z akblazeacademy.net -n "@" -y

# revoke and delete the certificate locally (optional)
certbot revoke --config-dir .certbot/config --work-dir .certbot/work --logs-dir .certbot/logs \
  --cert-name akblazeacademy.net --non-interactive
rm -rf .certbot

# remove the cron line with: crontab -e

# controller, CRDs, cluster (optional)
helm uninstall ngf -n nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
az aks delete --resource-group akblaze-rg --name akblaze-aks --yes --no-wait
```

---

## 🩺 Troubleshooting

### Certificate issuance

| Symptom | Check |
| --- | --- |
| `az CLI is not logged in` | Run `az login`. In cron, use a service principal or managed identity. |
| `can't read DNS zone` | `DNS_RG` must be the resource group of the **DNS zone**, which may differ from the cluster's. Also check `AZ_SUBSCRIPTION` and your **DNS Zone Contributor** role. |
| `Incorrect TXT record` / `NXDOMAIN looking up TXT` | The zone isn't really delegated to Azure, so Let's Encrypt asks your registrar's nameservers. Compare `nslookup -type=NS akblazeacademy.net` with the zone's `nameServers`. |
| `[auth] record not visible after 3 minutes` | Azure DNS is slow or the record went to the wrong zone. Look at `az network dns record-set txt list -g <rg> -z <zone> -o table` while the script runs. |
| `too many certificates already issued` | Production rate limit hit. Wait (the error says until when), and use `STAGING=1` while experimenting. |
| `is not inside the DNS zone` | Every name in `CERT_DOMAINS` must end with `DNS_ZONE`. |
| certbot log | `.certbot/logs/letsencrypt.log` has every request and response. |

### Gateway and HTTPS

| Symptom | Check |
| --- | --- |
| `https` listener `ResolvedRefs=False` | Secret missing or misnamed. `kubectl get secret akblaze-tls -n webapps`; it must be type `kubernetes.io/tls` in the **same namespace** as the Gateway. |
| Browser: "Your connection is not private" | Still on the staging cert. Set `STAGING=0` and re-run `issue-cert.sh`. Confirm with `./scripts/cert-status.sh`. |
| Browser shows the NGINX default/self-signed cert | The request didn't match the listener hostname. You must browse to exactly `akblazeacademy.net`; `www.` or the raw IP won't match. |
| `cert-status.sh` shows the new cert in the Secret but the old one live | Give it a few seconds. If it persists, find the Gateway's data-plane Deployment with `kubectl get deploy -n webapps` (NGF 2.x names it `akblaze-gateway-nginx`) and `kubectl rollout restart` it. |
| HTTP doesn't redirect | `kubectl describe httproute akblaze-http-redirect -n webapps`: is it `Accepted` on the `http` listener? |
| HTTPS times out but HTTP works | Port 443 isn't exposed. `kubectl get svc -n webapps` should show the Gateway's LoadBalancer with both 80 and 443. Check NSG rules if you added custom ones. |
| `/app1` returns 404 | The `URLRewrite` filter is missing or unsupported by your controller. Test the Pod directly: `kubectl port-forward -n webapps svc/app1 8080:80`, then `curl localhost:8080/`. |
| Footer badge says ⚠️ plain HTTP | You reached the page without the redirect, for example through `port-forward`. Expected in that case. |

---

**Stack:** Kubernetes Gateway API `v1` · NGINX Gateway Fabric · HTTPS listener with TLS termination · `RequestRedirect` + `URLRewrite` · certbot + Let's Encrypt (DNS-01 via Azure DNS hooks) · nginx-unprivileged serving static HTML from ConfigMaps.
