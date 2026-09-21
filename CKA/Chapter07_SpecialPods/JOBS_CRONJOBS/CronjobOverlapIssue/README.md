# Kubernetes CronJob `concurrencyPolicy` — Allow vs Forbid vs Replace

A hands-on demo of what happens when a CronJob's runs **overlap**. Every CronJob here fires
**every minute** but each job takes **2 minutes** to finish — so a new run is always due
*before* the previous one ends. The only difference between the three files is the
`concurrencyPolicy`, and that one field completely changes the behaviour.

```
schedule: */1 * * * *   → a new run is due every 1 minute
job runtime: sleep 120  → each run takes 2 minutes
                          → runs OVERLAP → concurrencyPolicy decides what happens
```

---

## What this demo teaches

A CronJob's **`concurrencyPolicy`** controls what Kubernetes does when it's time to start a
new job but the **previous job is still running**. There are three values:

| Policy      | When a new run is due and the old one is still running…                          | Overlap? |
|-------------|---------------------------------------------------------------------------------|----------|
| **Allow**   | Starts the new job anyway — both run at the same time. *(default)*               | ✅ Yes   |
| **Forbid**  | **Skips** the new run; waits for the current one to finish.                      | ❌ No    |
| **Replace** | **Kills** the running job and starts a fresh one in its place.                   | ❌ No    |

Why it matters:
- **Allow** is fine for independent tasks, but overlapping runs of something like a backup or
  a report can double-load a database or corrupt output.
- **Forbid** protects a task that must never run twice at once — you just accept that a slow
  run causes the next tick to be skipped.
- **Replace** is for "only the latest matters" tasks — cancel the stale run, always work on
  the newest.

This demo also shows **`successfulJobsHistoryLimit` / `failedJobsHistoryLimit`** (in
`allow.yaml`), which cap how many finished Jobs Kubernetes keeps around.

---

## Files in this repo

| File            | `concurrencyPolicy` | What you'll observe                                             |
|-----------------|---------------------|----------------------------------------------------------------|
| `allow.yaml`    | `Allow`             | Multiple jobs running **at the same time**. Also sets history limits (keep 2 successful / 1 failed). |
| `forbid.yaml`   | `Forbid`            | Only **one** job at a time; new ticks are **skipped** until it finishes. |
| `replace.yaml`  | `Replace`           | The running job is **deleted** and replaced by a new one each tick. |
| `createnamespace`| n/a                | Commands to make and switch to the `cron-demo` namespace.       |

All three use the same busybox container: `echo Started → sleep 120 → echo Finished`, with
`restartPolicy: Never`.

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Setup

### 1. Create the namespace and switch to it
(from the `createnamespace` file)
```bash
kubectl create namespace cron-demo
kubectl config set-context --current --namespace=cron-demo
```
Now every command below runs inside `cron-demo` without needing `-n`.

> **Do the three policies one at a time.** Apply one, watch it for ~4–5 minutes to see the
> behaviour, then delete it before starting the next — otherwise the running jobs get mixed
> together and it's hard to tell them apart.

---

## Demo A — `Allow` (overlap permitted, the default)

### 2. Apply it
```bash
kubectl apply -f allow.yaml
```

### 3. Watch jobs pile up in parallel
```bash
kubectl get jobs -w
```
After ~2 minutes you'll see **more than one job Running/active at once** — the minute-2 job
starts while the minute-1 job is still in its `sleep 120`.

### 4. Confirm with the pods
```bash
kubectl get pods
```
Expected — two (or more) `Running` pods overlapping:
```
NAME                        READY   STATUS    ...
cron-allow-28...-abcde      1/1     Running
cron-allow-28...-fghij      1/1     Running
```

### 5. See the history limit in action
```bash
kubectl get jobs
```
Because `successfulJobsHistoryLimit: 2`, Kubernetes keeps only the **last 2 completed** jobs;
older ones are garbage-collected. Without this, finished jobs accumulate forever.

### 6. Clean up before the next demo
```bash
kubectl delete -f allow.yaml
```

---

## Demo B — `Forbid` (no overlap, skip the new run)

### 7. Apply it
```bash
kubectl apply -f forbid.yaml
kubectl get jobs -w
```

### 8. Observe
There is **never more than one active job**. When the minute ticks over and the previous job
is still running (it needs 2 min), Kubernetes **skips** that scheduled run entirely.

### 9. See the "missed" scheduling in events
```bash
kubectl describe cronjob cron-forbid
```
Look at the `Events` section — you'll see messages about jobs still active / runs being
skipped rather than a new job every minute.

### 10. Clean up
```bash
kubectl delete -f forbid.yaml
```

---

## Demo C — `Replace` (no overlap, kill the old, start fresh)

### 11. Apply it
```bash
kubectl apply -f replace.yaml
kubectl get jobs -w
```

### 12. Observe
Each minute, the **currently running job is terminated** and a **new one takes its place** —
so you again never see two at once, but unlike `Forbid`, the old run doesn't get to finish.
Watch a pod get deleted mid-`sleep` and a fresh pod appear.

### 13. Watch the swap on the pods
```bash
kubectl get pods -w
```
You'll see a pod go `Terminating` while a new `cron-replace-...` pod starts.

### 14. Clean up
```bash
kubectl delete -f replace.yaml
```

---

## Quick comparison of what you saw

| Policy    | Jobs running at once | Slow run's fate               | Good for                              |
|-----------|----------------------|-------------------------------|---------------------------------------|
| `Allow`   | 2+ (overlap)         | Keeps running; new one joins  | Independent, safe-to-parallelize work |
| `Forbid`  | 1                    | Finishes; next tick skipped   | Tasks that must never double-run      |
| `Replace` | 1                    | Killed; replaced by new run   | "Only the latest run matters" tasks   |

---

## Key takeaways

- `concurrencyPolicy` only matters when a run is **still going** as the next one is **due** —
  this demo forces that with a 2-min job on a 1-min schedule.
- **Allow** = overlap (default), **Forbid** = skip, **Replace** = kill-and-restart.
- `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` keep finished Jobs from piling up.
- In real life, pick the policy from your task's safety: a DB backup usually wants `Forbid`
  (never two at once); a "latest snapshot" job often wants `Replace`.

---

## Cleanup

```bash
# remove any remaining cronjob
kubectl delete -f allow.yaml -f forbid.yaml -f replace.yaml --ignore-not-found

# reset your kubectl context back to the default namespace
kubectl config set-context --current --namespace=default

# delete the namespace (removes everything in it)
kubectl delete namespace cron-demo
```
