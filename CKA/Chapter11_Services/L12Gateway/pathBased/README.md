# 🧭 Gateway API Path Routing Demo: One Domain, Two Apps on Kubernetes + Azure DNS

Two working web apps and a landing page behind **one** Kubernetes Gateway, **one** public IP and **one** hostname. The [Kubernetes Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/) routes on the **URL path**:

| You open in a browser | You get |
| --- | --- |
| `http://akblazeacademy.net/` | 🏠 **Landing page** with links to both apps |
| `http://akblazeacademy.net/app1` | ✅ **TaskFlow**: to-do manager with priorities, filters, inline editing and a progress ring |
| `http://akblazeacademy.net/app2` | 💸 **Spendly**: income and expense tracker in ₹ with a category breakdown |

Both apps are fully functional and save their data in the browser (`localStorage`). Each page's footer shows **which Pod served it**, so you can watch the load balancing happen.

```
                 Azure DNS zone: akblazeacademy.net
                 @ (apex)  A  ->  <GATEWAY_PUBLIC_IP>
                                  │
                                  ▼
                   ┌──────────────────────────────┐
                   │  Gateway  akblaze-gateway    │  1 public IP, port 80
                   │  listener "http"             │  hostname akblazeacademy.net
                   └──────────────┬───────────────┘
                                  │
                   ┌──────────────┴───────────────┐
                   │  HTTPRoute  akblaze-routes   │
                   │  (longest path prefix wins)  │
                   └──┬────────────┬───────────┬──┘
           /app1/...  │  /app2/... │           │  / (everything else)
     rewrite → /...   │  rewrite → /...        │
                      ▼            ▼           ▼
                 Service app1  Service app2  Service home
                  2 Pods        2 Pods        1 Pod
             (nginx + ConfigMap HTML, shared nginx config)
```

### Host-based vs path-based routing

| | Host-based (previous demo) | Path-based (this demo) |
| --- | --- | --- |
| URLs | `app1.example.com`, `app2.example.com` | `example.com/app1`, `example.com/app2` |
| DNS records | One per app | **One** (the apex) |
| Gateway listeners | One per hostname | **One** |
| Where the split happens | Listener `hostname` + HTTPRoute `hostnames` | HTTPRoute `rules[].matches[].path` |
| Extra concern | None | Strip the prefix with a `URLRewrite` filter so apps can live at `/` |

---

## 📁 Repository layout

```
gateway-path-demo/
├── README.md
├── apps/
│   ├── home.html                  # landing page source (edit here)
│   ├── app1.html                  # TaskFlow source (edit here)
│   └── app2.html                  # Spendly source (edit here)
├── nginx/
│   └── default.conf               # shared nginx config: port 8080, /whoami, /healthz
├── manifests/
│   ├── 00-namespace.yaml          # namespace "webapps"
│   ├── 10-gateway.yaml            # Gateway with ONE listener for akblazeacademy.net
│   ├── 20-nginx-conf-configmap.yaml   # generated from nginx/default.conf
│   ├── 21-home-configmap.yaml         # generated from apps/home.html
│   ├── 22-app1-configmap.yaml         # generated from apps/app1.html
│   ├── 23-app2-configmap.yaml         # generated from apps/app2.html
│   ├── 30-home.yaml               # Deployment + Service (landing page)
│   ├── 31-app1.yaml               # Deployment + Service (TaskFlow)
│   ├── 32-app2.yaml               # Deployment + Service (Spendly)
│   ├── 40-httproute.yaml          # 1 HTTPRoute, 3 path rules, prefix rewrite
│   └── kustomization.yaml
└── scripts/
    └── build-configmaps.sh        # regenerate ConfigMaps after editing apps/ or nginx/
```

---

## ✅ Prerequisites

- A Kubernetes cluster (this guide uses **AKS**, but any cluster works).
- `kubectl` **v1.29+**, `helm` **v3.8+** and, for AKS, the `az` CLI logged in (`az login`).
- Your **Azure DNS zone `akblazeacademy.net` already delegated**, meaning your registrar's nameservers point at the Azure zone's NS records. Check with:
  ```bash
  az network dns zone show -g <dns-rg> -n akblazeacademy.net --query nameServers -o tsv
  nslookup -type=NS akblazeacademy.net     # should list the same Azure nameservers
  ```
- Permission to create Kubernetes resources and Azure DNS record sets.

> **Using a different domain?** The hostname `akblazeacademy.net` appears in `manifests/10-gateway.yaml` and `manifests/40-httproute.yaml`. Search and replace it in both files.

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
kubectl get nodes    # should list Ready nodes
```

---

## 2️⃣ Install the Gateway API CRDs

`GatewayClass`, `Gateway` and `HTTPRoute` are **not** built into Kubernetes. Install them as CRDs first:

```bash
# Match this version to what your Gateway controller supports.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# verify
kubectl get crd | grep gateway.networking.k8s.io
```

You should see `gatewayclasses`, `gateways`, `httproutes` and a few more.

---

## 3️⃣ Install a Gateway controller (NGINX Gateway Fabric)

The Gateway API is only an API. You need an implementation that provisions a load balancer and proxies the traffic. This demo targets **NGINX Gateway Fabric (NGF)**, which creates a `GatewayClass` named `nginx`.

```bash
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --create-namespace -n nginx-gateway

# Controller running, GatewayClass accepted
kubectl get pods -n nginx-gateway
kubectl get gatewayclass          # 'nginx' should show ACCEPTED=True
```

> **Using something else?** Any conformant controller works: Istio, Envoy Gateway, Cilium, or **Azure Application Gateway for Containers**. Install it, note the GatewayClass name it creates, and set `spec.gatewayClassName` in `manifests/10-gateway.yaml`. The `URLRewrite` filter used in this demo is an *extended* Gateway API feature; NGF, Istio and Envoy Gateway support it, but check your controller's docs if you use a different one.

---

## 4️⃣ Deploy the apps, the Gateway and the route

```bash
# from the repo root
kubectl apply -k manifests/
#   ...or:  kubectl apply -f manifests/

# watch everything come up
kubectl get pods,svc,gateway,httproute -n webapps
```

Wait until:

- 5 Pods are `Running` and `1/1` ready (2 × `app1`, 2 × `app2`, 1 × `home`)
- the Gateway shows `PROGRAMMED=True`
- the HTTPRoute is `Accepted` with `ResolvedRefs=True`

```bash
kubectl wait --for=condition=Programmed gateway/akblaze-gateway -n webapps --timeout=180s

kubectl get httproute akblaze-routes -n webapps \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
# Accepted=True
# ResolvedRefs=True
```

---

## 5️⃣ Get the Gateway's public IP

NGF creates a `LoadBalancer` Service for the Gateway and Azure assigns it a public IP. This can take 1–3 minutes. The Gateway reports the address in its status, which works with any controller:

```bash
GATEWAY_IP=$(kubectl get gateway akblaze-gateway -n webapps \
  -o jsonpath='{.status.addresses[0].value}')

echo "Gateway public IP: $GATEWAY_IP"
```

If it's empty, the load balancer is still provisioning. Re-run in a minute, or find the Service directly:

```bash
kubectl get svc -A | grep LoadBalancer
# NGF 2.x creates it in the Gateway's namespace, e.g. webapps/akblaze-gateway-nginx
```

---

## 6️⃣ Test routing before DNS exists

You can prove the path routing works right now by sending the `Host` header straight to the IP:

```bash
for p in / /app1/ /app2/; do
  printf "%-8s " "$p"
  curl -s -H "Host: akblazeacademy.net" "http://$GATEWAY_IP$p" | grep -o '<title>.*</title>'
done
# /        <title>akblazeacademy · App Portal</title>
# /app1/   <title>TaskFlow · akblazeacademy /app1</title>
# /app2/   <title>Spendly · akblazeacademy /app2</title>
```

Three different pages from one IP and one hostname, chosen only by the path.

---

## 7️⃣ Point Azure DNS at the Gateway

Path-based routing needs just **one A record**, at the **zone apex** (`@`), so the bare domain `akblazeacademy.net` resolves to the Gateway.

```bash
RG=akblaze-rg                    # resource group that holds the DNS zone
ZONE=akblazeacademy.net

# akblazeacademy.net  ->  Gateway IP
az network dns record-set a add-record \
  --resource-group "$RG" \
  --zone-name "$ZONE" \
  --record-set-name "@" \
  --ipv4-address "$GATEWAY_IP"

# (optional) shorten the TTL so changes propagate fast while testing
az network dns record-set a update -g "$RG" -z "$ZONE" -n "@" --set ttl=60

# verify
az network dns record-set a show -g "$RG" -z "$ZONE" -n "@" \
  --query "{fqdn:fqdn, ttl:TTL, ips:ARecords[].ipv4Address}" -o json
```

> **`@` means the zone itself.** `--record-set-name "@"` inside zone `akblazeacademy.net` creates the record for `akblazeacademy.net`. Don't type the full domain as the name; that would create `akblazeacademy.net.akblazeacademy.net`.

> **Want `www.akblazeacademy.net` too?** Add a second A record named `www`, then add `www.akblazeacademy.net` to the Gateway listener (use a second listener, since a listener takes one hostname) and to the HTTPRoute `hostnames` list.

---

## 8️⃣ Verify DNS and play 🎉

```bash
nslookup akblazeacademy.net          # should return $GATEWAY_IP
curl -s http://akblazeacademy.net/app1/ | grep -o '<title>.*</title>'
```

Then open in a browser:

- **http://akblazeacademy.net/** for the landing page
- **http://akblazeacademy.net/app1** for TaskFlow: add tasks, set priorities, double-click to edit, filter, watch the progress ring
- **http://akblazeacademy.net/app2** for Spendly: add income and expenses, see the balance and the per-category bars update

---

## 🔬 How the path routing works

### The HTTPRoute rules

`manifests/40-httproute.yaml` has three rules on the same hostname:

```yaml
rules:
  - matches: [{ path: { type: PathPrefix, value: /app1 } }]
    filters:
      - type: URLRewrite
        urlRewrite:
          path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
    backendRefs: [{ name: app1, port: 80 }]
  - matches: [{ path: { type: PathPrefix, value: /app2 } }]
    filters: [ ...same rewrite... ]
    backendRefs: [{ name: app2, port: 80 }]
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs: [{ name: home, port: 80 }]
```

Three Gateway API rules do the work:

1. **Longest prefix wins.** `/app1/whoami` matches both `/app1` and `/`, but `/app1` is longer, so it goes to `app1`. Rule order in the file doesn't matter.
2. **Prefixes match whole path segments.** `/app1` matches `/app1` and `/app1/anything`, but **not** `/app10` or `/app1x`. Those fall through to the landing page.
3. **The rewrite strips the prefix.** The browser asks for `/app1/whoami`; the Pod receives `/whoami`.

| Browser requests | Rule matched | Backend | Pod receives |
| --- | --- | --- | --- |
| `/` | `/` | `home` | `/` |
| `/app1` | `/app1` | `app1` | `/` |
| `/app1/` | `/app1` | `app1` | `/` |
| `/app1/whoami` | `/app1` | `app1` | `/whoami` |
| `/app2/` | `/app2` | `app2` | `/` |
| `/app10` | `/` | `home` | `/app10` (served the landing page) |

### Why the rewrite matters

Without the `URLRewrite` filter, the app1 Pod would receive `/app1/` and nginx would look for `/usr/share/nginx/html/app1/index.html`, which doesn't exist, and return a 404. The rewrite lets every app be built and tested as if it lived at `/`, and you can move it to any prefix by editing only the HTTPRoute.

The flip side: **links inside an app must be relative**. The apps call `whoami` relative to their own prefix (`/app1/whoami`), never `/whoami`, which would go to the landing page instead. If you add images or scripts to an app, reference them as `logo.png`, not `/logo.png`.

### The shared nginx config

All three Deployments mount the same `nginx-conf` ConfigMap over `/etc/nginx/conf.d/default.conf`. It adds:

| Location | Purpose |
| --- | --- |
| `/whoami` | Returns the Pod name. Each page calls it to fill in the footer. |
| `/healthz` | Returns `ok`. Used by the readiness and liveness probes. |
| `X-Served-By` header | Added to every response with the Pod name. |
| `absolute_redirect off` | Keeps nginx's internal port 8080 out of any redirect URLs. |

### Browser storage note

Both apps share the origin `http://akblazeacademy.net`, so they share one `localStorage`. They use separate keys (`akblaze.app1.tasks` and `akblaze.app2.transactions`) to avoid clobbering each other. This is a real trade-off of path-based routing: apps on one domain also share cookies and storage, while apps on separate subdomains don't.

---

## 📈 Watch load balancing and routing live

Use two terminals.

**Terminal 1:** hit each app repeatedly and print which Pod answered:

```bash
watch -n 1 '
for app in app1 app2; do
  printf "%s: " $app
  for i in 1 2 3 4 5 6; do curl -s http://akblazeacademy.net/$app/whoami | tr "\n" " "; done
  echo
done'
```

You'll see the two `app1-…` Pod names alternate on the first line and the two `app2-…` Pod names on the second.

**Terminal 2:** change things and watch Terminal 1 react:

```bash
# scale app1 to 4 replicas: four different Pod names appear
kubectl scale deployment app1 -n webapps --replicas=4

# kill an app2 Pod: its name disappears, a new one replaces it
kubectl delete $(kubectl get pod -n webapps -l app=app2 -o name | head -1) -n webapps

# scale app2 to zero: its line switches to an error page from the Gateway
kubectl scale deployment app2 -n webapps --replicas=0
kubectl scale deployment app2 -n webapps --replicas=2    # restore
```

Or check the header without the body:

```bash
curl -sI http://akblazeacademy.net/app1/ | grep -i x-served-by
```

---

## 🔁 Editing an app

The HTML lives in `apps/` and the nginx config in `nginx/`. The Pods read them from ConfigMaps, so after editing, regenerate the ConfigMaps and roll the Pods:

```bash
# 1. edit apps/app1.html, apps/app2.html, apps/home.html or nginx/default.conf
# 2. regenerate the ConfigMap manifests
./scripts/build-configmaps.sh
# 3. apply and restart so Pods pick up the new content
kubectl apply -k manifests/
kubectl rollout restart deployment/app1 deployment/app2 deployment/home -n webapps
```

### Adding an `/app3`

1. Copy `apps/app1.html` to `apps/app3.html` and change it.
2. Add a `gen "app3-html" ...` line to `scripts/build-configmaps.sh` and run it.
3. Copy `manifests/31-app1.yaml` to `33-app3.yaml`, replacing every `app1` with `app3`.
4. Add a rule to `40-httproute.yaml` with `value: /app3` and `backendRefs: [{ name: app3, port: 80 }]`.
5. Add the two new files to `kustomization.yaml` and run `kubectl apply -k manifests/`.

No DNS changes and no Gateway changes are needed. That's the main appeal of path-based routing.

---

## 🔐 Add HTTPS (optional next step)

This demo is HTTP only. To serve `https://akblazeacademy.net`:

1. Install **cert-manager** and create a Let's Encrypt `ClusterIssuer`, or bring your own certificate as a Kubernetes TLS `Secret`.
2. Add an `HTTPS` listener on port 443 to `manifests/10-gateway.yaml` with a `tls.certificateRefs` entry pointing at that Secret.
3. Point the HTTPRoute's `parentRefs` at the new listener, and optionally add a second HTTPRoute on the port-80 listener with a `RequestRedirect` filter (`scheme: https`).

Since there's only one hostname, a single certificate covers every app. See the [Gateway API TLS guide](https://gateway-api.sigs.k8s.io/guides/tls/).

---

## 🧹 Cleanup

```bash
# apps, route and Gateway (also releases the public IP)
kubectl delete -k manifests/

# DNS record
az network dns record-set a delete -g "$RG" -z "$ZONE" -n "@" -y

# controller and CRDs (optional)
helm uninstall ngf -n nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# the whole cluster, if you created it just for this
az aks delete --resource-group akblaze-rg --name akblaze-aks --yes --no-wait
```

---

## 🩺 Troubleshooting

| Symptom | Check |
| --- | --- |
| Gateway `PROGRAMMED=False` | `kubectl describe gateway akblaze-gateway -n webapps`. Is the controller running? Does `gatewayClassName` match `kubectl get gatewayclass`? |
| HTTPRoute not `Accepted` | `kubectl describe httproute akblaze-routes -n webapps`. `sectionName: http` must match the listener name, and the route hostname must match the listener hostname. |
| `ResolvedRefs=False` | A `backendRefs` Service name or port is wrong. `kubectl get svc -n webapps` should show `app1`, `app2` and `home` on port 80. |
| `/app1` returns **404** | The `URLRewrite` filter is missing or unsupported by your controller, so the Pod is receiving `/app1/`. Test the Pod directly: `kubectl port-forward -n webapps svc/app1 8080:80`, then `curl localhost:8080/`. |
| `/app1` shows the **landing page** | The `/app1` rule didn't match. Check the path value in the HTTPRoute for typos, and remember `/App1` ≠ `/app1`. |
| Footer says `Served by pod unknown` | The `whoami` call failed. Run `curl -s http://akblazeacademy.net/app1/whoami`. If the landing page comes back, the request isn't reaching app1. |
| Pods not ready | `kubectl describe pod -n webapps -l app=app1`. A failing `/healthz` probe usually means the `nginx-conf` ConfigMap wasn't applied. |
| No IP on the Gateway | Azure is still provisioning. Check `kubectl get svc -A \| grep LoadBalancer` and `kubectl get events -n webapps`. |
| IP assigned but requests time out | Check that the Azure Load Balancer health probe for port 80 is healthy in the portal. If it probes an HTTP path that returns 404, set the annotation `service.beta.kubernetes.io/azure-load-balancer-health-probe-protocol: tcp` on the Gateway's LoadBalancer Service (if the controller reverts manual edits, set it through the NGF Helm values for the NGINX Service). |
| `curl -H "Host: …"` works but the domain doesn't | DNS hasn't propagated or the apex record points at the wrong IP. Re-check step 7 and run `nslookup akblazeacademy.net 8.8.8.8`. |
| Data from one app shows up in the other | It won't with the shipped apps, but any new app must use its own `localStorage` keys because all apps share one origin. |

---

**Stack:** Kubernetes Gateway API `v1` · NGINX Gateway Fabric (`gatewayClassName: nginx`) · HTTPRoute `PathPrefix` + `URLRewrite` · Azure DNS apex record · nginx-unprivileged serving static HTML from ConfigMaps.
