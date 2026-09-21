# Kubernetes Scheduling Demo: Taints/Tolerations, Cordon, and Drain

A hands-on teaching lab. You will taint a node and watch pods get repelled and
evicted, cordon a node and watch scheduling stop, drain a node and watch it
**stall, refuse, and get bypassed** — and understand *exactly why* in each case.

Works on any cluster with **2+ nodes** (kind, minikube with `--nodes 2`, k3d, or
a real cluster). Everything uses the tiny `pause` image, so nothing real runs.

---

## 0. The one-paragraph mental model

- **Taint** lives on a **node**. It *repels* pods. ("Keep out.")
- **Toleration** lives on a **pod**. It's a *pass* for a matching taint. ("I may enter.")
- **Cordon** marks a node **unschedulable**. *New* pods stop landing; existing pods stay.
- **Drain** = **cordon** + **evict** everything that can be safely moved off the node.

Taints/tolerations decide **permission**. Cordon/drain are **operator actions** you
run to take a node out of service (patching, scaling down, decommissioning).

---

## 1. Setup

```bash
# A 2-node kind cluster is ideal so evicted pods have somewhere to go.
kind create cluster --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kubectl get nodes
# Pick a worker to experiment on and save it:
export NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}')
echo "Using node: $NODE"
```

---

## 2. Taints & Tolerations

### 2a. NoSchedule — repel *new* pods

```bash
kubectl taint nodes "$NODE" dedicated=team-a:NoSchedule
kubectl apply -f manifests/01-taint-noschedule.yaml

kubectl get pods -o wide -l demo=taints
```

You'll see:
- `no-toleration` → may be **Pending** (if it can't fit on another node) or land on a
  *different* node. `kubectl describe pod no-toleration` shows
  `node(s) had untolerated taint {dedicated: team-a}`.
- `with-toleration` → **allowed** on `$NODE` (but only *pulled* there if nothing else fits;
  a toleration is permission, not attraction — pair with `nodeSelector` to force it).

> **Key point:** a toleration does **not** pull a pod onto a node. It only removes the
> block. To *target* the node, add `nodeSelector`/`nodeAffinity` as well.

Clean up:
```bash
kubectl delete -f manifests/01-taint-noschedule.yaml
kubectl taint nodes "$NODE" dedicated=team-a:NoSchedule-   # trailing "-" removes it
```

### 2b. NoExecute — also *evict* running pods

```bash
# Put three pods on the node FIRST (before the taint), so we can watch eviction.
kubectl apply -f manifests/02-taint-noexecute.yaml
kubectl get pods -o wide -l demo=noexecute       # wait until Running

kubectl taint nodes "$NODE" maintenance=true:NoExecute
kubectl get pods -o wide -l demo=noexecute -w     # watch
```

Outcome:
| Pod                   | Toleration                              | Result                       |
|-----------------------|-----------------------------------------|------------------------------|
| `evicted-immediately` | none                                    | Terminated at once           |
| `grace-30s`           | NoExecute + `tolerationSeconds: 30`     | Terminated after ~30s        |
| `stays-forever`       | NoExecute via `Exists`, no seconds      | Keeps running                |

Clean up:
```bash
kubectl taint nodes "$NODE" maintenance=true:NoExecute-
kubectl delete -f manifests/02-taint-noexecute.yaml
```

### 2c. Toleration operators & the "tolerate everything" wildcard

`manifests/03-toleration-operators.yaml` shows `Equal` vs `Exists`, and the
**universal pass** (`operator: Exists` with no key/effect) that system agents use.
That wildcard is *the* reason some pods survive every taint you throw — remember it
when a taint "doesn't work."

---

## 3. Cordon — stop new pods, disturb nothing

```bash
kubectl apply -f manifests/04-deployment-for-cordon-drain.yaml
kubectl get pods -o wide -l app=web              # note which land on $NODE

kubectl cordon "$NODE"
kubectl get node "$NODE"                          # STATUS: Ready,SchedulingDisabled
```

Now delete a web pod that was on `$NODE` and watch where its replacement goes:
```bash
kubectl delete pod <one-web-pod-on-$NODE>
kubectl get pods -o wide -l app=web               # replacement avoids $NODE
```

**What cordon did:** set `.spec.unschedulable=true` on the node. Existing pods were
untouched; only *new* scheduling is blocked.

Uncordon when done:
```bash
kubectl uncordon "$NODE"
```

### Cordon under the hood (and how it's bypassed)

Cordon works by making the **default scheduler** skip the node. Anything that places
pods **without** the default scheduler ignores cordon:
- **DaemonSet controller** → keeps putting its pods on cordoned nodes (see §5).
- **Pods with `spec.nodeName` set directly** (static pods, or hand-pinned pods) →
  bypass the scheduler entirely, so cordon can't stop them.

---

## 4. Drain — cordon **plus** evict

```bash
kubectl drain "$NODE" --ignore-daemonsets
```

Drain does two things: cordons the node, then uses the **Eviction API** to remove
pods so they reschedule elsewhere. Managed pods (`web`) move; the node ends up
running only what can't/shouldn't be moved.

This is where most real-world pain lives. Below are the failure modes and the
exact bypass for each.

---

## 5. When drain FAILS or is BYPASSED (the important part)

Drain is deliberately cautious. It **refuses** or **stalls** rather than cause data
loss or an outage. Each guard has a specific override.

### 5a. PodDisruptionBudget → drain **stalls** (retries forever)

The Eviction API honors PDBs. If evicting the next pod would breach the budget, it
returns `429` and drain keeps retrying.

```bash
kubectl apply -f manifests/05-pdb-blocks-drain.yaml   # minAvailable: 4 of 4
kubectl drain "$NODE" --ignore-daemonsets
# -> "Cannot evict pod ... would violate the pod's disruption budget." (hangs)
```
**Why:** you asked for 4 always-up, so 0 may be disrupted.
**Fixes:** raise replicas, or lower `minAvailable` to 3, or `kubectl delete pdb web-pdb`.
**Hard bypass:** drain has *no* flag to skip PDBs. Deleting pods directly does
(see §5e) — because that skips the Eviction API entirely.

### 5b. Bare (unmanaged) pod → drain **refuses to start**

```bash
kubectl apply -f manifests/06-bare-pod-blocks-drain.yaml
kubectl drain "$NODE" --ignore-daemonsets
# -> "cannot delete Pods declared no controller (use --force to override)"
```
**Why:** nothing would recreate it; evicting = losing it.
**Bypass:** `kubectl drain "$NODE" --ignore-daemonsets --force` (the bare pod is deleted for good).

### 5c. Pod with local storage (emptyDir) → drain **refuses to start**

```bash
kubectl apply -f manifests/08-emptydir-blocks-drain.yaml
kubectl drain "$NODE" --ignore-daemonsets
# -> "cannot delete Pods with local storage (use --delete-emptydir-data to override)"
```
**Bypass:** `kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data`
(you accept losing the emptyDir contents).

### 5d. DaemonSet pods → drain **errors**, then is **ignored by design**

```bash
kubectl apply -f manifests/07-daemonset-ignored-by-drain.yaml
kubectl drain "$NODE"
# -> "cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore)"
```
**Bypass:** `--ignore-daemonsets` — but note this doesn't *evict* them; it **leaves
them running**. A "drained" node still runs its DaemonSet pods. That's expected:
they're recreated instantly anyway, and they also **ignore cordon** (§3).

### 5e. The nuclear bypass: skip the Eviction API entirely

Everything above goes through the polite **Eviction API** (which respects PDBs and
graceful termination). You can go around it with a **direct delete**:

```bash
kubectl delete pod <name> --grace-period=0 --force
```
This does **not** consult PDBs and gives no graceful shutdown. It's how you force
progress when a PDB is misconfigured — and how you *accidentally* cause an outage.
Use it knowingly.

### 5f. All-blockers-at-once run

```bash
kubectl drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30 \
  --timeout=120s
```
This is the command you'll actually use in production: ignore DaemonSets, accept
emptyDir loss, delete bare pods, cap grace at 30s, and give up after 120s instead
of hanging forever on a PDB.

---

## 6. Cordon vs Drain vs Taint — the differences

| Dimension            | Taint (NoSchedule)      | Taint (NoExecute)        | Cordon                       | Drain                              |
|----------------------|-------------------------|--------------------------|------------------------------|------------------------------------|
| Lives on / is a…     | Node property           | Node property            | Node flag (`unschedulable`)  | Client-side *action* (kubectl)     |
| Blocks new pods?     | Yes (unless tolerated)  | Yes (unless tolerated)   | Yes (all, via scheduler)     | Yes (it cordons first)             |
| Evicts running pods? | No                      | **Yes** (unless tolerated)| No                          | **Yes** (via Eviction API)         |
| Selective?           | Yes — per key/value     | Yes — per key/value      | No — whole node              | No — whole node                    |
| Respects PDB?        | n/a                     | n/a                      | n/a                          | **Yes** (can stall)                |
| Bypassed by          | matching toleration     | matching toleration      | DaemonSets, `nodeName` pins  | DaemonSets, `--force`, direct delete |
| Undo                 | `kubectl taint … -`     | `kubectl taint … -`      | `kubectl uncordon`           | `kubectl uncordon`                 |
| Typical use          | Reserve nodes (GPU/team)| Evacuate on a condition  | Freeze a node                | Take a node out for maintenance    |

**Relationship:** `drain ⊇ cordon`. Drain *is* a cordon followed by eviction.
Taints are the mechanism; a `NoExecute` taint is effectively a *targeted, automatic*
drain that only removes pods lacking the matching toleration.

---

## 7. What bypasses what — quick reference

| Guardrail                     | What it stops                     | How it's bypassed                                  |
|-------------------------------|-----------------------------------|----------------------------------------------------|
| `NoSchedule` taint            | new untolerated pods              | matching **toleration** (or `Exists` wildcard)     |
| `NoExecute` taint             | untolerated pods running/arriving | toleration; `tolerationSeconds` delays eviction    |
| **Cordon**                    | default-scheduler placement       | **DaemonSet** pods; pods with `spec.nodeName` set  |
| **Drain** → DaemonSet check   | drain proceeding                  | `--ignore-daemonsets` (leaves them running)        |
| **Drain** → bare-pod check    | drain proceeding                  | `--force` (deletes the pod permanently)            |
| **Drain** → emptyDir check    | drain proceeding                  | `--delete-emptydir-data` (data lost)               |
| **Drain** → **PDB**           | eviction of protected pods        | fix/scale/delete PDB; or `delete --force` (skips API)|
| Node full (not a taint)       | scheduling for lack of resources  | higher **PriorityClass** preempts lower pods (§8)  |

---

## 8. Bonus: priority/preemption (a different kind of bypass)

`manifests/09-critical-priority-bypass.yaml` shows how a high-`PriorityClass` pod
**preempts** lower-priority pods when a node is *full*. This bypasses a **resource**
constraint — not a taint and not cordon. A preemptor still needs a toleration for a
tainted node and still won't land on a cordoned one. `system-node-critical` /
`system-cluster-critical` are why core components rarely get evicted.

---

## 9. Teardown

```bash
kubectl delete -f manifests/ --ignore-not-found
kubectl uncordon "$NODE" 2>/dev/null || true
for t in dedicated=team-a:NoSchedule maintenance=true:NoExecute; do
  kubectl taint nodes "$NODE" "${t}-" 2>/dev/null || true
done
# or just: kind delete cluster
```

---

## 10. Suggested teaching order (≈30–40 min)

1. Mental model (§0) — 3 min.
2. NoSchedule, then NoExecute with the eviction table (§2) — 10 min.
3. Cordon; show existing pods survive, new ones divert (§3) — 5 min.
4. Drain the happy path (§4) — 3 min.
5. Break drain four ways and bypass each (§5) — 12 min. *This is the payoff.*
6. Differences + bypass tables (§6, §7) — 5 min.
7. Priority/preemption as contrast (§8) — optional 3 min.
