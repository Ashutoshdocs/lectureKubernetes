# Kubernetes NetworkPolicy: Ingress & Egress — End-to-End Demo

A hands-on lab that starts with a wide-open cluster and locks it down one step at a time.
After every step you run `./test.sh <stage>`. It tries 11 connections and tells you whether each result is what that stage should produce.

By the end you will understand:

- the difference between **ingress** (who may connect *to* a pod) and **egress** (where a pod may connect *to*)
- how **default-deny** policies work
- why **DNS breaks** the moment you restrict egress, and how to fix it
- that a connection needs **both** the source's egress **and** the destination's ingress to allow it
- how to allow **internet** traffic without opening the whole cluster
- the **AND vs OR** selector trap that catches almost everyone

---

## 1. The scenario

```
                     ┌──────────────────────── namespace: shop ────────────────────────┐
                     │                                                                  │
 ┌───────────┐       │   ┌──────────┐        ┌──────────┐        ┌──────────┐          │
 │  client   │ ────────▶ │ frontend │ ─────▶ │ backend  │ ─────▶ │    db    │          │
 │ (outsider │       │   └──────────┘        └────┬─────┘        └──────────┘          │
 │ namespace)│       │                            │                                     │
 └───────────┘       │                            ▼                                     │
                     │                      🌍 internet (80/443)                         │
                     └──────────────────────────────────────────────────────────────────┘
          + every shop pod may reach kube-dns (kube-system, port 53)
```

**Target state (the final stage):**

| Rule | Type |
|---|---|
| Only the `outsider` namespace can reach **frontend** | Ingress |
| Only **frontend** can reach **backend** | Ingress + Egress |
| Only **backend** can reach **db** | Ingress + Egress |
| Only **backend** can reach the internet | Egress |
| **db** cannot open any outgoing connection | Egress |
| All shop pods can use DNS | Egress |

Every nginx pod replies with:

```
You successfully hit <podname> under <namespace> and the DNS name of the service for the pod is <service DNS>
```

---

## 2. Files

| File | Stage | What it does |
|---|---|---|
| `00-namespaces.yaml` | setup | Creates `shop` and `outsider` |
| `01-apps.yaml` | setup | frontend / backend / db (nginx + Service) and a busybox `client` |
| `02-default-deny-ingress.yaml` | 1 | Blocks **all incoming** traffic to shop pods |
| `03-allow-ingress.yaml` | 2 | Re-opens only the incoming paths we want |
| `04-default-deny-egress.yaml` | 3 | Blocks **all outgoing** traffic from shop pods (DNS included!) |
| `05-allow-dns-egress.yaml` | 4 | Re-opens DNS |
| `06-allow-egress.yaml` | 5 | Re-opens only the outgoing paths we want |
| `test.sh` | all | Runs the 11-check connectivity matrix |

---

## 3. Prerequisites

You need a cluster whose network plugin (CNI) **enforces** NetworkPolicy, such as Calico, Cilium or Antrea.
Some common default plugins accept NetworkPolicy objects but ignore them; kindnet and flannel are two examples.

The easiest option is minikube with Calico:

```bash
minikube start --cni=calico
kubectl get pods -n kube-system | grep calico     # wait until Running
```

You also need `kubectl` and `bash`. The test runs `wget`/`nslookup` *inside* the pods, so you don't need any extra tools on your laptop.

```bash
chmod +x test.sh
```

---

## 4. Five rules to remember before you start

1. **No policy selects a pod → the pod is wide open.** Kubernetes networking allows everything by default.
2. **When a policy selects a pod for a direction, that direction becomes allow-list only.** Once any policy with `policyTypes: [Ingress]` selects a pod, the pod accepts *only* the traffic some policy explicitly allows in. Egress works the same way.
3. **Policies only add permissions.** Nothing "denies" in the sense of overriding. The allowed traffic is the union of every policy that selects the pod, so the order you apply them in does not matter.
4. **Both ends must agree.** A → B works only if A's egress allows B **and** B's ingress allows A, whenever each side is isolated in that direction.
5. **Replies are automatic.** Policies are stateful. If a request is allowed in, its response is allowed back out, so you never write rules for return traffic.

---

## 5. Walkthrough

### Setup

```bash
kubectl apply -f 00-namespaces.yaml -f 01-apps.yaml
```

### Stage 0: no policies (everything open)

```bash
./test.sh 0
```

All 11 checks show **ALLOWED**. Even the `outsider` client can reach the database directly. This is the default, and it is why NetworkPolicies exist.

---

### Stage 1: default-deny **ingress**

```bash
kubectl apply -f 02-default-deny-ingress.yaml
./test.sh 1
```

```yaml
spec:
  podSelector: {}          # every pod in the namespace
  policyTypes: ["Ingress"] # ...is now isolated for incoming traffic
                           # (no ingress rules = nothing allowed in)
```

**What happened:** no pod in `shop` accepts connections any more, from outside or from each other.
**What still works:** DNS lookups and internet access, because those are *outgoing* and egress is untouched.

---

### Stage 2: allow specific **ingress**

```bash
kubectl apply -f 03-allow-ingress.yaml
./test.sh 2
```

| Policy | Allows *into* the pod |
|---|---|
| `frontend-allow-from-outsider` | anything in namespace `outsider` |
| `backend-allow-from-frontend` | pods labelled `app: frontend` (same namespace) |
| `db-allow-from-backend` | pods labelled `app: backend` |

**What happened:** the chain client → frontend → backend → db works. Skipping a hop fails: outsider → db is blocked, and frontend → db is blocked. Going backwards also fails, for example db → backend.

Note that frontend can still reach **the internet**. Ingress policies say nothing about outgoing traffic, and that gap is why we need egress.

---

### Stage 3: default-deny **egress** (expect breakage)

```bash
kubectl apply -f 04-default-deny-egress.yaml
./test.sh 3
```

**What happened:** almost everything broke, including frontend → backend, which stage 2 had just allowed. Why?

- frontend first has to **resolve** `backend.shop.svc.cluster.local`. That DNS query is egress to kube-dns, and egress is now denied.
- Even with an IP address, frontend's egress would still need to allow backend (rule 4: both ends must agree).

**Only outsider → frontend still works.** The client's own namespace has no egress policy, frontend's ingress allows it, and frontend's reply is automatic (rule 5).

> 💡 **The #1 real-world NetworkPolicy mistake:** applying default-deny egress without allowing DNS.

---

### Stage 4: allow **DNS** egress

```bash
kubectl apply -f 05-allow-dns-egress.yaml
./test.sh 4
```

```yaml
egress:
  - to:
      - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
        podSelector:       { matchLabels: { k8s-app: kube-dns } }
    ports:
      - { protocol: UDP, port: 53 }
      - { protocol: TCP, port: 53 }
```

**What happened:** the DNS check passes again. Pod-to-pod and internet traffic are still blocked, because nothing allows that egress yet.

---

### Stage 5: allow specific **egress**

```bash
kubectl apply -f 06-allow-egress.yaml
./test.sh 5
```

| Policy | Allows *out of* the pod |
|---|---|
| `frontend-egress-to-backend` | → backend:80 |
| `backend-egress-to-db-and-internet` | → db:80, and → any **public** IP on 80/443 |
| *(none for db)* | db stays fully egress-denied |

The internet rule uses `ipBlock` and excludes private ranges:

```yaml
- ipBlock:
    cidr: 0.0.0.0/0
    except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
```

Without the `except` list, `0.0.0.0/0` would also match pod and node IPs inside the cluster. That would silently re-open internal traffic.

**What happened:** the target state is reached. Compare it with stage 2: the internal paths are identical, but now **frontend can't reach the internet** while **backend can**. That difference is egress at work.

---

### Expected results for every stage

| # | Check | S0 | S1 | S2 | S3 | S4 | S5 |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|
| 1 | outsider → frontend | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 2 | outsider → backend | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 3 | outsider → db | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 4 | frontend → backend | ✅ | ❌ | ✅ | ❌ | ❌ | ✅ |
| 5 | frontend → db | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 6 | backend → db | ✅ | ❌ | ✅ | ❌ | ❌ | ✅ |
| 7 | backend → frontend | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 8 | db → backend | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 9 | frontend DNS lookup | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| 10 | frontend → internet | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 11 | backend → internet | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |

---

## 6. The AND vs OR trap

These two snippets look almost identical but mean very different things.

```yaml
# AND: one list item with both selectors
# "pods labelled app=prometheus that live in namespace monitoring"
ingress:
  - from:
      - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
        podSelector:       { matchLabels: { app: prometheus } }
```

```yaml
# OR: two list items (notice the second dash)
# "ANY pod in namespace monitoring" OR "pods labelled app=prometheus in MY namespace"
ingress:
  - from:
      - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
      - podSelector:       { matchLabels: { app: prometheus } }
```

One extra `-` turns a tight rule into a much looser one, so always check the dashes.

---

## 7. Exercises

<details>
<summary><b>1. Delete <code>04-default-deny-egress.yaml</code>. Does anything change? Why?</b></summary>

Nothing changes. `05-allow-dns-egress.yaml` also uses `podSelector: {}` with `policyTypes: [Egress]`, so it already isolates every shop pod for egress (rule 2). The default-deny policy is a safety net: it keeps pods locked down even if someone later deletes or edits the other egress policies.

```bash
kubectl delete -f 04-default-deny-egress.yaml && ./test.sh 5
kubectl apply  -f 04-default-deny-egress.yaml
```
</details>

<details>
<summary><b>2. Delete only the DNS policy at stage 5. Which checks fail?</b></summary>

Checks 4, 6, 9 and 11 fail. Everything that uses a name needs DNS first. The `ipBlock` rule cannot help, because kube-dns has a private cluster IP and that range is excluded.
</details>

<details>
<summary><b>3. Let <code>db</code> reach the internet on port 443 only.</b></summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-egress-https, namespace: shop }
spec:
  podSelector: { matchLabels: { app: db } }
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
      ports: [{ protocol: TCP, port: 443 }]
```
</details>

<details>
<summary><b>4. Let backend also call frontend. Which file(s) must change?</b></summary>

Two policies must change, because of rule 4.

- Frontend's **ingress** must allow `app: backend`: add a second `from` entry to `frontend-allow-from-outsider`.
- Backend's **egress** must allow `app: frontend`: add a `to` entry to `backend-egress-to-db-and-internet`.

If you change only one of them, check 7 stays blocked.
</details>

<details>
<summary><b>5. Add a pod in the <code>outsider</code> namespace labelled <code>app: attacker</code>. Can it reach frontend? How would you stop it?</b></summary>

Yes. `frontend-allow-from-outsider` allows the *whole* namespace. To restrict it, put a `podSelector: { matchLabels: { app: client } }` in the **same list item** as the `namespaceSelector` (the AND form from section 6).
</details>

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Stage 1 still shows everything ALLOWED | Your CNI doesn't enforce NetworkPolicy. Use `minikube start --cni=calico` or install Calico or Cilium. |
| DNS still fails at stage 4 | Your DNS pods use a different label. Run `kubectl get pods -n kube-system --show-labels \| grep -i dns` and update `05-allow-dns-egress.yaml`. With NodeLocal DNSCache, also allow its IP (often `169.254.20.10/32`) through an `ipBlock`. |
| Backend → internet blocked at stage 5 | Your network or a corporate proxy blocks `example.com`, or your nodes need a proxy. Test from the node first. |
| Results flip-flop right after `apply` | Policies can take a second or two to apply. Re-run the test. |
| Want to see what applies to a pod | `kubectl get networkpolicy -n shop` and `kubectl describe networkpolicy <name> -n shop` |

---

## 9. Cleanup

```bash
kubectl delete namespace shop outsider
```

To restart from stage 0 without recreating the apps:

```bash
kubectl delete networkpolicy --all -n shop
```
