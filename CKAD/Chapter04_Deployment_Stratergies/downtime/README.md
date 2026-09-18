# Kubernetes `Recreate` Deployment Strategy — Downtime Demo

A demo of the **`Recreate`** deployment strategy, which shows *why* it causes **downtime**
during an update. With `Recreate`, Kubernetes **kills all old pods first**, and only *then*
starts the new ones — so for a moment there are **zero pods serving**.

```
Recreate update:

  [old v1] [old v1]          ← running
        │  terminate ALL old pods
        ▼
     (no pods running)        ← ⚠️ DOWNTIME window
        │  start new pods
        ▼
  [new v2] [new v2]          ← running again
```

Contrast with the default **`RollingUpdate`**, which brings new pods up *before* removing old
ones, so there's no gap.

---

## What this demo teaches

### Deployment update strategies
A Deployment's `strategy.type` controls how pods are replaced during an update:

| Strategy | Behaviour during update | Downtime? |
|----------|-------------------------|-----------|
| **`RollingUpdate`** (default) | New pods come up, then old ones are removed, gradually | ❌ No |
| **`Recreate`** | **All** old pods are terminated **first**, then new ones start | ✅ Yes (a gap) |

### Why `Recreate` exists
It looks strictly worse, but it's the right choice when **old and new versions must never run
at the same time** — for example:
- An app that takes an **exclusive lock** on a database or file.
- A **schema migration** where mixing versions would corrupt data.
- Software that simply **can't run two instances** against the same backend.

In those cases a brief downtime is an acceptable price for never having v1 and v2 live
together.

### What you'll observe here
This Deployment sets `strategy.type: Recreate` with 2 replicas. When you change the image,
you'll watch **both old pods go `Terminating` and fully disappear before** the new pods are
created — the visible downtime window.

---

## Files in this repo

| File            | What it is                                                          |
|-----------------|--------------------------------------------------------------------|
| `downtime.yml`  | A Deployment (`recreate-demo`, 2 replicas, `nginx:1.23`) using `strategy.type: Recreate`. |
| `downtime_steps.txt` | The apply + image-update commands.                            |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Steps

### 1. Deploy the app
```bash
kubectl apply -f downtime.yml
```

### 2. Confirm both pods are running
```bash
kubectl get pods -l app=demo2
```
Expected — 2 pods running `nginx:1.23`:
```
NAME                             READY   STATUS    RESTARTS   AGE
recreate-demo-xxxxxxxxx-aaaaa    1/1     Running   0          ...
recreate-demo-xxxxxxxxx-bbbbb    1/1     Running   0          ...
```

### 3. Start watching the pods (keep this running)
In one terminal:
```bash
kubectl get pods -l app=demo2 -w
```

### 4. Trigger an update by changing the image
In another terminal:
```bash
kubectl set image deployment/recreate-demo demo=nginx:1.24
```

### 5. Watch the downtime window in the first terminal
Because the strategy is `Recreate`, you'll see **all old pods terminate first**, a moment with
**no Running pods**, then the new ones appear:
```
recreate-demo-...-aaaaa   1/1   Terminating
recreate-demo-...-bbbbb   1/1   Terminating
recreate-demo-...-aaaaa   0/1   Terminating
recreate-demo-...-bbbbb   0/1   Terminating
                                          ← ⚠️ no pods Running here = downtime
recreate-demo-...-ccccc   0/1   Pending
recreate-demo-...-ddddd   0/1   Pending
recreate-demo-...-ccccc   1/1   Running
recreate-demo-...-ddddd   1/1   Running
```
That empty gap is the whole lesson: with `Recreate`, the app is briefly **completely down**.

### 6. Confirm the rollout finished
```bash
kubectl rollout status deployment/recreate-demo
kubectl get pods -l app=demo2
```

---

## See it in the rollout events

```bash
kubectl describe deployment recreate-demo
```
In the `Events` section you'll see it **scale the old ReplicaSet down to 0** before scaling
the new one up — the signature of `Recreate` (a `RollingUpdate` would interleave the two).

---

## Compare: make it zero-downtime

To feel the difference, switch the strategy to the default and repeat the image change — new
pods come up *before* old ones leave, so there's no gap:
```yaml
spec:
  strategy:
    type: RollingUpdate       # (the default)
```
```bash
kubectl apply -f downtime.yml
kubectl set image deployment/recreate-demo demo=nginx:1.25
kubectl get pods -l app=demo2 -w      # old + new overlap; never zero Running
```

---

## Key takeaways

- **`strategy.type` decides update behaviour.** `Recreate` = terminate all old pods **before**
  creating new ones → a **downtime gap**.
- The default **`RollingUpdate`** overlaps old and new pods, so there's no downtime.
- Choose `Recreate` only when **two versions must never run simultaneously** (exclusive locks,
  migrations); otherwise prefer `RollingUpdate`.
- Watching `kubectl get pods -w` during the update is the clearest way to *see* the gap.

---

## Cleanup

```bash
kubectl delete -f downtime.yml
```
