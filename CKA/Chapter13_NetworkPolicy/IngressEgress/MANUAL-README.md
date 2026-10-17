# NetworkPolicy Demo — Manual Walkthrough (Presenter Script)

This is the step-by-step command script for presenting the demo **live, by hand**, one `kubectl` command at a time.
To run every check automatically instead, use `./test.sh <stage>` (see `README.md`).

Run every command from inside the `netpol-demo` folder.

**Legend:** ✅ = should succeed  ❌ = should fail  💬 = talking point

---

## Before you start

You need a cluster whose CNI enforces NetworkPolicy, such as Calico or Cilium:

```bash
minikube start --cni=calico
```

**Presenter tip:** open a second terminal and leave this running, so the audience sees policies appear and disappear:

```bash
watch kubectl get networkpolicy -n shop
```

### Error messages to recognise

| Message | Meaning |
|---|---|
| `You successfully hit … under shop …` | ✅ Connection allowed |
| `wget: download timed out` | ❌ Connection blocked by a policy |
| `wget: bad address '…'` | ❌ **DNS** failed; the name couldn't be resolved |
| `;; connection timed out; no servers could be reached` | ❌ `nslookup` could not reach kube-dns |

---

## Setup

```bash
kubectl apply -f 00-namespaces.yaml -f 01-apps.yaml
kubectl get pods -n shop -o wide
kubectl get pods -n outsider
kubectl get svc -n shop
```

Wait until all pods are `Running`.

💬 *"We have a three-tier app (frontend → backend → db) in `shop`, and a client in a different namespace called `outsider`."*

---

## Stage 0: everything is open

```bash
kubectl get networkpolicy -n shop
```
Output: `No resources found`

```bash
# outsider can reach every tier, even the database
kubectl exec -n outsider client -- wget -qO- -T 3 http://frontend.shop.svc.cluster.local   # ✅
kubectl exec -n outsider client -- wget -qO- -T 3 http://db.shop.svc.cluster.local         # ✅

# frontend can reach the internet
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://example.com | head -5        # ✅
```

💬 *"By default, Kubernetes allows all pod-to-pod traffic. Anyone in the cluster can talk to our database directly. That's the problem NetworkPolicies solve."*

---

## Stage 1: default-deny ingress

```bash
kubectl apply -f 02-default-deny-ingress.yaml
kubectl describe networkpolicy default-deny-ingress -n shop
```

```bash
kubectl exec -n outsider client      -- wget -qO- -T 3 http://frontend.shop.svc.cluster.local   # ❌ timed out
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local    # ❌ timed out
```

```bash
# outgoing traffic is untouched
kubectl exec -n shop deploy/frontend -- nslookup backend.shop.svc.cluster.local              # ✅
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://example.com | head -5          # ✅
```

💬 *"`podSelector: {}` selects every pod. `policyTypes: [Ingress]` with no rules means nothing may come in. Outgoing traffic (DNS, internet) still works, because ingress rules only control incoming traffic."*

---

## Stage 2: allow specific ingress

```bash
kubectl apply -f 03-allow-ingress.yaml
kubectl get networkpolicy -n shop
```

**The allowed chain works:**
```bash
kubectl exec -n outsider client      -- wget -qO- -T 3 http://frontend.shop.svc.cluster.local   # ✅
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local    # ✅
kubectl exec -n shop deploy/backend  -- wget -qO- -T 3 http://db.shop.svc.cluster.local         # ✅
```

**Skipping a hop or going backwards fails:**
```bash
kubectl exec -n outsider client      -- wget -qO- -T 3 http://db.shop.svc.cluster.local         # ❌
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://db.shop.svc.cluster.local         # ❌
kubectl exec -n shop deploy/db       -- wget -qO- -T 3 http://backend.shop.svc.cluster.local    # ❌
```

**The gap that's still open:**
```bash
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://example.com | head -5             # ✅
```

💬 *"Policies are additive. These allow-rules add to the default-deny. But notice that frontend can still reach the internet. If frontend were compromised, it could send data anywhere. We need egress control."*

---

## Stage 3: default-deny egress (it breaks)

```bash
kubectl apply -f 04-default-deny-egress.yaml
```

```bash
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local
```
❌ Output: `wget: bad address 'backend.shop.svc.cluster.local'`

💬 *"Look at the error. It isn't a timeout, it's 'bad address'. That's DNS failing."* Prove it:

```bash
kubectl exec -n shop deploy/frontend -- nslookup backend.shop.svc.cluster.local                # ❌
```

```bash
# incoming traffic still works
kubectl exec -n outsider client -- wget -qO- -T 3 http://frontend.shop.svc.cluster.local      # ✅
```

💬 *"Two lessons here. First, a DNS query is egress, so denying egress kills name resolution. This is the most common NetworkPolicy mistake in real life. Second, outsider → frontend still works, because policies are stateful: the reply to an allowed request is automatically allowed back."*

---

## Stage 4: allow DNS egress

```bash
kubectl apply -f 05-allow-dns-egress.yaml
```

```bash
kubectl exec -n shop deploy/frontend -- nslookup backend.shop.svc.cluster.local                # ✅ resolves
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local   # ❌ timed out
```

💬 *"The error changed from 'bad address' to 'timed out'. The name resolves now, but frontend's egress still doesn't allow backend. Each layer has to be opened explicitly."*

---

## Stage 5: allow specific egress

```bash
kubectl apply -f 06-allow-egress.yaml
kubectl get networkpolicy -n shop
```

**Internal paths work again:**
```bash
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local   # ✅
kubectl exec -n shop deploy/backend  -- wget -qO- -T 3 http://db.shop.svc.cluster.local        # ✅
```

**Internet: only backend is allowed:**
```bash
kubectl exec -n shop deploy/backend  -- wget -qO- -T 3 http://example.com | head -5            # ✅
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://example.com                      # ❌
```

**db stays fully locked down:**
```bash
kubectl exec -n shop deploy/db -- wget -qO- -T 3 http://backend.shop.svc.cluster.local         # ❌
```

💬 *"This is the target state. The internal paths are the same as stage 2, but now frontend can't reach the internet while backend can. The `ipBlock` rule excludes private ranges, so `0.0.0.0/0` doesn't accidentally re-open internal traffic."*

---

## Bonus: live "aha" moments

### Both ends must allow the connection

```bash
kubectl delete networkpolicy backend-allow-from-frontend -n shop
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local   # ❌
```
💬 *"Frontend's egress still allows backend, but backend's ingress no longer allows frontend. Both sides must agree."*

```bash
kubectl apply -f 03-allow-ingress.yaml        # restore
kubectl exec -n shop deploy/frontend -- wget -qO- -T 3 http://backend.shop.svc.cluster.local   # ✅
```

### Toggle DNS live

```bash
kubectl delete -f 05-allow-dns-egress.yaml
kubectl exec -n shop deploy/frontend -- nslookup backend.shop.svc.cluster.local                # ❌

kubectl apply -f 05-allow-dns-egress.yaml
kubectl exec -n shop deploy/frontend -- nslookup backend.shop.svc.cluster.local                # ✅
```

### Show the whole matrix at once

```bash
./test.sh 5
```

---

## Reset and cleanup

```bash
# back to stage 0 (apps stay, policies removed)
kubectl delete networkpolicy --all -n shop

# remove everything
kubectl delete namespace shop outsider
```

---

## Quick reference: what each stage proves

| Stage | Apply | Key command to show | Expected |
|---|---|---|---|
| 0 | none | outsider → db | ✅ wide open |
| 1 | `02-default-deny-ingress.yaml` | outsider → frontend | ❌ timed out |
| 2 | `03-allow-ingress.yaml` | outsider → db / frontend → internet | ❌ / ✅ (gap) |
| 3 | `04-default-deny-egress.yaml` | frontend → backend | ❌ bad address (DNS) |
| 4 | `05-allow-dns-egress.yaml` | frontend → backend | ❌ timed out (DNS ok) |
| 5 | `06-allow-egress.yaml` | backend → internet / frontend → internet | ✅ / ❌ |
