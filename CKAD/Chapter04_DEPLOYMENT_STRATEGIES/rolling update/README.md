# Kubernetes `RollingUpdate` Strategy — Zero-Downtime Demo

A demo of the default **`RollingUpdate`** deployment strategy: Kubernetes replaces pods
**gradually**, bringing new ones up **before** removing old ones, so the app keeps serving the
whole time — **no downtime**. This is the opposite of the `Recreate` strategy (which kills all
old pods first).

```
RollingUpdate (maxSurge:1, maxUnavailable:1) with 3 replicas:

  [v1][v1][v1]              ← start: 3 old pods serving
  [v1][v1][v1][v2]          ← +1 new (surge), still serving
  [v1][v1]    [v2]          ← -1 old
  [v1][v1][v2][v2]          ← +1 new
       ...                  ← repeats, always ≥2 pods available
  [v2][v2][v2]              ← done, never went to zero
```

---

## What this demo teaches

### Rolling updates
`RollingUpdate` swaps pods **a few at a time** instead of all at once. Because new pods are
started and become Ready before old ones are torn down, there are **always enough pods
serving traffic** — the update is invisible to users.

### The two knobs: `maxSurge` and `maxUnavailable`
These control *how fast* and *how safely* the roll happens (this file sets both to `1`):

| Setting | Meaning | In this demo (3 replicas) |
|---------|---------|---------------------------|
| **`maxSurge: 1`** | How many pods **above** the desired count may exist during the update | Up to **4** pods can run briefly |
| **`maxUnavailable: 1`** | How many pods **below** the desired count may be unavailable | At least **2** pods stay available at all times |

So during the roll the pod count stays between **2 (available)** and **4 (total)** — never
zero. Both can be numbers or percentages (e.g. `25%`).

### Rollout history & rollback
Every rollout is **versioned**. Kubernetes keeps a **history** of revisions, so if a new
version is bad you can **roll back** to the previous one with one command.

---

## Files in this repo

| File                  | What it is                                                                 |
|-----------------------|---------------------------------------------------------------------------|
| `rollingupate.yml`    | Deployment `rolling-demo` (3 replicas, `nginx:1.23`) with `RollingUpdate`, `maxSurge:1`, `maxUnavailable:1`. |
| `rolling_update_steps.txt` | The apply + image-update + history commands.                         |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Steps

### 1. Deploy the app
```bash
kubectl apply -f rollingupate.yml
kubectl rollout status deployment/rolling-demo
```
Expected — the rollout completes and 3 pods run `nginx:1.23`:
```
deployment "rolling-demo" successfully rolled out
```

### 2. Start watching the pods (keep this open)
In one terminal:
```bash
kubectl get pods -l app=demo -w
```

### 3. Trigger a rolling update (change the image)
In another terminal:
```bash
kubectl set image deployment/rolling-demo demo=nginx:1.24
```

### 4. Watch pods roll over gradually
In the watch terminal you'll see new pods appear and become Ready **before** old ones are
removed — the count never drops to zero:
```
rolling-demo-OLD-aaaaa   1/1   Running
rolling-demo-OLD-bbbbb   1/1   Running
rolling-demo-OLD-ccccc   1/1   Running
rolling-demo-NEW-ddddd   0/1   Pending      ← surge: a 4th pod starts
rolling-demo-NEW-ddddd   1/1   Running      ← new ready...
rolling-demo-OLD-aaaaa   1/1   Terminating  ← ...then an old one leaves
   ... repeats until all 3 are new ...
```
Compare this to `Recreate`, where all old pods vanish first. Here there's **always ≥2
available**.

### 5. Confirm the rollout completed
```bash
kubectl rollout status deployment/rolling-demo
kubectl get pods -l app=demo -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
# → all show nginx:1.24
```

---

## Rollout history & rollback

### 6. View the revision history
```bash
kubectl rollout history deployment/rolling-demo
```
You'll see revision 1 (`nginx:1.23`) and revision 2 (`nginx:1.24`).

> **Tip:** to get useful descriptions in the `CHANGE-CAUSE` column, add `--record` to the
> command that made the change, or annotate it:
> ```bash
> kubectl annotate deployment/rolling-demo kubernetes.io/change-cause="update to nginx 1.24"
> ```

### 7. Roll back to the previous version
Simulate a bad release and undo it — this itself is a rolling update, so it's also
zero-downtime:
```bash
kubectl rollout undo deployment/rolling-demo
kubectl rollout status deployment/rolling-demo
```
Roll back to a **specific** revision instead:
```bash
kubectl rollout undo deployment/rolling-demo --to-revision=1
```

### 8. (Optional) Pause and resume a rollout
Useful for a canary-style check mid-roll:
```bash
kubectl rollout pause deployment/rolling-demo
# ...make changes / observe...
kubectl rollout resume deployment/rolling-demo
```

---

## Try changing the knobs

Edit `rollingupate.yml` and re-apply to feel the difference:
- `maxSurge: 0, maxUnavailable: 1` → never exceeds 3 pods, but drops to 2 available (slower,
  no extra capacity).
- `maxSurge: 3, maxUnavailable: 0` → spins up all 3 new pods first, keeps all 3 old available
  (fastest, most resource-hungry — closest to blue-green).

```bash
kubectl apply -f rollingupate.yml
kubectl set image deployment/rolling-demo demo=nginx:1.25
kubectl get pods -l app=demo -w
```

---

## Key takeaways

- **`RollingUpdate`** (the default) replaces pods **gradually**, keeping the app available
  throughout — **no downtime**.
- **`maxSurge`** = how many extra pods may run during the roll; **`maxUnavailable`** = how many
  may be missing. Together they set the speed/safety trade-off.
- Rollouts are **versioned**: `kubectl rollout history` lists revisions and
  `kubectl rollout undo` rolls back instantly.
- Use `kubectl get pods -w` during the update to *see* new pods come up before old ones leave.

---

## Cleanup

```bash
kubectl delete -f rollingupate.yml
```
