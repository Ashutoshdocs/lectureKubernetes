# Kubernetes Services Under the Hood: Watching kube-proxy iptables Rules Live

This demo deploys a small nginx workload behind a ClusterIP Service. It then shows exactly how **kube-proxy** (in `iptables` mode) turns that Service into NAT rules on each node. You will:

1. Create Pods and a Service
2. Trace a packet's path through the `KUBE-SERVICES` → `KUBE-SVC-*` → `KUBE-SEP-*` chains
3. Watch the rules **rewrite themselves live** as you scale, delete Pods and drain all endpoints
4. Watch the per-rule packet counters prove that traffic really is load-balanced

---

## Prerequisites

| Requirement | Notes |
|---|---|
| A Kubernetes cluster | kind, minikube, kubeadm or any self-managed cluster. **Managed clusters that replace kube-proxy (e.g. Cilium eBPF, GKE Dataplane V2) won't show these rules.** |
| `kubectl` | Configured against the cluster |
| Root shell on a node | See [Getting a shell on a node](#getting-a-shell-on-a-node) |
| `watch` | Included in `procps` on most distros |

### Confirm kube-proxy is in iptables mode

```bash
# From your workstation
kubectl -n kube-system get configmap kube-proxy -o yaml | grep -i "mode:"
# mode: ""         -> empty means the default, which is iptables on Linux
# mode: "iptables" -> good
# mode: "ipvs" or "nftables" -> this demo's chains won't exist

# Or, from a node
curl -s localhost:10249/proxyMode
```

### Getting a shell on a node

```bash
# kind
docker exec -it kind-worker bash        # or kind-control-plane for single-node clusters

# minikube
minikube ssh
sudo -i

# Regular VMs / bare metal
ssh user@<node-ip>
sudo -i
```

> Every node runs kube-proxy and gets the **same** Service rules, so any node works. You don't have to be on the node where the Pods are scheduled.

---

## Step 1: Create the Pods and the Service

Create `app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
  - port: 8080
    targetPort: 80
```

Apply it and wait for the Pods:

```bash
kubectl apply -f app.yaml
kubectl rollout status deployment/web-app
```

---

## Step 2: Gather the IPs

```bash
# Service ClusterIP
kubectl get svc web-service
# NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
# web-service   ClusterIP   10.96.124.55   <none>        8080/TCP   10s

# Pod IPs
kubectl get pods -l app=web -o wide
# NAME                       READY   STATUS    IP           NODE
# web-app-6d4cf56db6-abcde   1/1     Running   10.244.1.4   worker-1
# web-app-6d4cf56db6-fghij   1/1     Running   10.244.1.5   worker-1

# The endpoints kube-proxy is actually programming
kubectl get endpointslices -l kubernetes.io/service-name=web-service
```

The IPs used below are examples. Yours will differ.

---

## Step 3: Inspect the iptables Chains

Run everything in this step **as root on a node**.

### 3.0 Find this Service's chain name

The `KUBE-SVC-*` suffix is a hash, so look it up rather than guessing:

```bash
SVC_CHAIN=$(iptables -t nat -S KUBE-SERVICES \
  | grep 'default/web-service' \
  | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1)
echo "$SVC_CHAIN"
# KUBE-SVC-XXXXXXXXXXXXXXXX
```

### 3.1 Entry point: `KUBE-SERVICES`

Every packet aimed at a ClusterIP lands here first (it's hooked from `PREROUTING` and `OUTPUT`).

```bash
iptables -t nat -L KUBE-SERVICES -n | grep web-service
```

```text
KUBE-SVC-XXXXXX  tcp  --  0.0.0.0/0  10.96.124.55  /* default/web-service cluster IP */ tcp dpt:8080
```

**What happens:** traffic to `10.96.124.55:8080` jumps to the Service-specific chain `KUBE-SVC-XXXXXX`.

### 3.2 Load balancing: `KUBE-SVC-*`

```bash
iptables -t nat -L "$SVC_CHAIN" -n
```

```text
Chain KUBE-SVC-XXXXXX (1 references)
target           prot opt source          destination
KUBE-MARK-MASQ   tcp  --  !10.244.0.0/16  10.96.124.55  /* ... cluster IP */ tcp dpt:8080
KUBE-SEP-AAAAAA  all  --  0.0.0.0/0       0.0.0.0/0     /* ... -> 10.244.1.4:80 */ statistic mode random probability 0.50000000000
KUBE-SEP-BBBBBB  all  --  0.0.0.0/0       0.0.0.0/0     /* ... -> 10.244.1.5:80 */
```

**What happens:**
- `KUBE-MARK-MASQ` marks traffic coming from *outside* the Pod CIDR so it gets SNAT'd on the way out and replies return correctly.
- The `statistic` module picks the first endpoint with **50%** probability.
- Anything that doesn't match falls through to the last rule, which always matches.

### 3.3 DNAT to the Pod: `KUBE-SEP-*`

Each Service EndPoint chain rewrites the destination to one real Pod:

```bash
SEP_CHAIN=$(iptables -t nat -S "$SVC_CHAIN" | grep -o 'KUBE-SEP-[A-Z0-9]*' | head -1)
iptables -t nat -L "$SEP_CHAIN" -n
```

```text
Chain KUBE-SEP-AAAAAA (1 references)
target          prot opt source       destination
KUBE-MARK-MASQ  all  --  10.244.1.4   0.0.0.0/0    /* default/web-service */
DNAT            tcp  --  0.0.0.0/0    0.0.0.0/0    /* default/web-service */ tcp to:10.244.1.4:80
```

**What happens:**
- `DNAT` rewrites `10.96.124.55:8080` → `10.244.1.4:80`. The ClusterIP never exists on any interface; it's purely a NAT rule.
- `KUBE-MARK-MASQ` handles *hairpin* traffic, where a Pod reaches itself through its own Service.

### 3.4 The full chain in one view

```bash
iptables-save -t nat | grep 'web-service'
```

### Packet path summary

```text
Client Pod
   │  dst 10.96.124.55:8080
   ▼
PREROUTING / OUTPUT
   ▼
KUBE-SERVICES ──(match ClusterIP:port)──► KUBE-SVC-XXXXXX
                                              │
                         ┌────── p=0.5 ───────┤
                         ▼                    ▼ (fall-through)
                  KUBE-SEP-AAAAAA       KUBE-SEP-BBBBBB
                   DNAT → 10.244.1.4:80  DNAT → 10.244.1.5:80
```

---

## Step 4: Watch the Rules Update Live

kube-proxy watches the API server for Service and EndpointSlice changes and rewrites the rules whenever endpoints change. Use **two terminals** to see it happen.

### Terminal 1 (node, root): live view of the Service chain

```bash
SVC_CHAIN=$(iptables -t nat -S KUBE-SERVICES | grep 'default/web-service' \
  | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1)

watch -n 1 -d "iptables -t nat -L $SVC_CHAIN -n"
```

`-d` highlights whatever changed since the last refresh.

For a more compact view that also tells you which Pod each rule points to:

```bash
watch -n 1 -d "iptables-save -t nat | grep -E '^-A $SVC_CHAIN|^-A KUBE-SEP.*web-service.*DNAT'"
```

### Terminal 2 (workstation): make changes

#### 4.1 Scale up to 3 replicas

```bash
kubectl scale deployment web-app --replicas=3
```

Terminal 1 updates within a second or two:

```text
KUBE-SEP-AAAAAA ... statistic mode random probability 0.33333333349   -> Pod 1
KUBE-SEP-BBBBBB ... statistic mode random probability 0.50000000000   -> Pod 2
KUBE-SEP-CCCCCC ...                                                    -> Pod 3 (fall-through)
```

**Why these numbers?** Each rule only sees the traffic that the rules above it didn't take:

| Rule | Probability | Share of *total* traffic |
|---|---|---|
| Pod 1 | 1/3 | 1/3 |
| Pod 2 | 1/2 of the remaining 2/3 | 1/3 |
| Pod 3 | everything left (1/1) | 1/3 |

In general, with *n* endpoints the rule at position *i* (starting at 1) uses probability `1 / (n - i + 1)`.

#### 4.2 Scale up further, then back down

```bash
kubectl scale deployment web-app --replicas=5   # 1/5, 1/4, 1/3, 1/2, fall-through
kubectl scale deployment web-app --replicas=2   # back to 1/2, fall-through
```

#### 4.3 Delete a Pod and watch it get replaced

```bash
kubectl delete $(kubectl get pod -l app=web -o name | head -1)
```

In Terminal 1 one `KUBE-SEP-*` chain disappears and a new one, with the new Pod's IP and a new hash, takes its place.

#### 4.4 Remove all endpoints

```bash
kubectl scale deployment web-app --replicas=0
```

The `KUBE-SVC-*` chain empties out. kube-proxy then puts a `REJECT` rule in the **filter** table so clients fail fast instead of hanging:

```bash
iptables -t filter -L KUBE-SERVICES -n | grep web-service
# REJECT  tcp  --  0.0.0.0/0  10.96.124.55  /* default/web-service has no endpoints */ tcp dpt:8080 reject-with icmp-port-unreachable
```

Restore:

```bash
kubectl scale deployment web-app --replicas=3
```

---

## Step 5 (Bonus): Prove the Load Balancing with Packet Counters

The `-v` flag adds packet and byte counters to every rule.

**Terminal 2:** start a client that sends a steady stream of requests:

```bash
kubectl run load --image=curlimages/curl --restart=Never -it --rm -- \
  sh -c 'while true; do curl -s -o /dev/null web-service:8080; sleep 0.1; done'
```

**Terminal 1:** zero the counters, then watch them grow:

```bash
iptables -t nat -Z "$SVC_CHAIN"
watch -n 1 -d "iptables -t nat -L $SVC_CHAIN -n -v"
```

After a minute the `pkts` column should be roughly equal across the `KUBE-SEP-*` rules. Only the first packet of each connection traverses the NAT table, because conntrack handles the rest, so these counts are connections rather than packets.

To watch traffic from the Pods' side instead:

```bash
kubectl logs -l app=web -f --prefix
```

---

## Handy One-liners

```bash
# All Kubernetes Service rules for this Service
iptables-save -t nat | grep web-service

# Count endpoints currently programmed
iptables -t nat -S "$SVC_CHAIN" | grep -c KUBE-SEP

# Active NAT'd connections to the ClusterIP (needs conntrack-tools)
conntrack -L -d 10.96.124.55

# kube-proxy's view of things
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=50
```

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `grep web-service` returns nothing | kube-proxy isn't in iptables mode, or a CNI (e.g. Cilium) has replaced kube-proxy |
| `iptables: No chain/target/match by that name` | `$SVC_CHAIN` is empty. Re-run the lookup in step 3.0 |
| Rules look empty but traffic works | The node uses the nft backend and you're running `iptables-legacy`, or the other way round. Try `iptables-nft` / `iptables-legacy` explicitly |
| Rules update slowly | kube-proxy batches changes (`--iptables-min-sync-period`). A few seconds of delay on busy clusters is normal |
| `watch: command not found` in a kind node | `apt-get update && apt-get install -y procps` |

---

## Clean Up

```bash
kubectl delete -f app.yaml
kubectl delete pod load --ignore-not-found
```

---

## Key Takeaways

- A ClusterIP is **virtual**. No interface owns it; it exists only as iptables NAT rules on every node.
- kube-proxy uses three layers of chains: **`KUBE-SERVICES`** (match the Service), **`KUBE-SVC-*`** (pick an endpoint), **`KUBE-SEP-*`** (DNAT to the Pod).
- Equal load balancing comes from chained probabilities `1/n, 1/(n-1), …, 1/1`.
- Rules are rewritten automatically whenever the set of **ready** endpoints changes, whether through scaling, Pod deletion or readiness probe failures.
- Selection is per **connection**, not per request. Long-lived keep-alive connections stick to one Pod.
