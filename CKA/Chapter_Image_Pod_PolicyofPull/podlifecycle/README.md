# Kubernetes Pod Lifecycle — Phase vs Status & Termination Exit Codes

A practical guide to how a Pod moves through its life, the difference between
**phase** and **status**, and what happens when a container exits with code `0`
versus a non-zero code. Includes runnable demos you can `kubectl apply` yourself.

---

## Table of Contents

1. [Pod Lifecycle Overview](#1-pod-lifecycle-overview)
2. [Pod Phases](#2-pod-phases)
3. [Phase vs Status — the key difference](#3-phase-vs-status--the-key-difference)
4. [Container States](#4-container-states)
5. [Restart Policy (this controls everything)](#5-restart-policy-this-controls-everything)
6. [Termination & Exit Codes](#6-termination--exit-codes)
7. [Demo 1 — Exit code 0 (success)](#demo-1--exit-code-0-success)
8. [Demo 2 — Non-zero exit code (failure)](#demo-2--non-zero-exit-code-failure)
9. [Demo 3 — CrashLoopBackOff](#demo-3--crashloopbackoff)
10. [Inspecting exit codes yourself](#inspecting-exit-codes-yourself)
11. [Quick Reference](#quick-reference)

---

## 1. Pod Lifecycle Overview

A Pod is not a long-lived, healed-forever object. It is created, scheduled, runs
its containers, and eventually terminates. The lifecycle looks like this:

```
   Created
      │
      ▼
  ┌─────────┐   image pull / scheduling
  │ Pending │
  └────┬────┘
       │ containers start
       ▼
  ┌─────────┐
  │ Running │◄──── (containers may restart here depending on restartPolicy)
  └────┬────┘
       │ all containers finished
       ▼
   ┌───────────────────────────┐
   │  Succeeded   OR   Failed  │   ← terminal states
   └───────────────────────────┘
```

Once a Pod reaches **Succeeded** or **Failed**, it is *terminal*. Kubernetes
does not resurrect a terminated Pod; a controller (Deployment, Job, etc.) would
create a **new** Pod instead.

---

## 2. Pod Phases

`.status.phase` is a **high-level, single-word summary** of where the Pod is in
its life. There are exactly five possible values:

| Phase       | Meaning                                                                                     |
|-------------|---------------------------------------------------------------------------------------------|
| `Pending`   | Pod accepted by the cluster but one or more containers not yet running (scheduling, image pull). |
| `Running`   | Pod bound to a node; at least one container is running (or starting/restarting).             |
| `Succeeded` | All containers terminated **successfully** (exit `0`) and will not be restarted.             |
| `Failed`    | All containers terminated, and **at least one failed** (non-zero exit) or was killed.        |
| `Unknown`   | State could not be obtained, usually a node/communication problem.                           |

Check it with:

```bash
kubectl get pod <name> -o jsonpath='{.status.phase}'
```

---

## 3. Phase vs Status — the key difference

This trips up almost everyone. **Phase and Status are not the same thing.**

| Aspect        | **Phase**                                  | **Status**                                                                 |
|---------------|--------------------------------------------|----------------------------------------------------------------------------|
| What it is    | One coarse word summarizing the whole Pod  | The **entire** `.status` object: phase + conditions + container states + IPs + timestamps |
| Field         | `.status.phase`                            | `.status` (the full sub-tree)                                              |
| Granularity   | Very coarse (5 values only)                | Fine-grained, per-container detail                                          |
| Example value | `Running`                                  | `phase: Running`, `conditions: [Ready=False]`, `containerStatuses: [waiting: CrashLoopBackOff]` |

> **Phase is a field inside Status.** Status is the big picture; phase is one line of it.

### Why this matters

A Pod can be in phase **`Running`** while a container inside it is repeatedly
crashing (`CrashLoopBackOff`). The *phase* still says `Running` because the Pod
is scheduled and active — but the *status* (specifically `containerStatuses` and
the `Ready` condition) tells the real story.

```bash
# Coarse view — just the phase
kubectl get pod web -o jsonpath='{.status.phase}{"\n"}'
# → Running

# Real view — the full status, including per-container trouble
kubectl get pod web -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
# → {"waiting":{"reason":"CrashLoopBackOff", ...}}
```

**The column you see in `kubectl get pods` under `STATUS` is NOT the phase.**
It's a human-friendly synthesized string (e.g. `CrashLoopBackOff`,
`ImagePullBackOff`, `Completed`, `Error`) computed from container states — which
is exactly why it can differ from the phase.

---

## 4. Container States

Each container in a Pod has its own state (part of Status, not Phase):

| State        | Meaning                                                                    |
|--------------|---------------------------------------------------------------------------|
| `Waiting`    | Not yet running — pulling image, waiting on a dependency, or backing off. Has a `reason` like `ImagePullBackOff` or `CrashLoopBackOff`. |
| `Running`    | Executing normally. Has a `startedAt` timestamp.                           |
| `Terminated` | Finished execution. Has `exitCode`, `reason`, `startedAt`, `finishedAt`.   |

The `exitCode` lives here: `.status.containerStatuses[*].state.terminated.exitCode`.

---

## 5. Restart Policy (this controls everything)

`.spec.restartPolicy` decides what happens **after a container exits**. It
applies to all containers in the Pod.

| Policy         | Behavior                                                            | Default for            |
|----------------|--------------------------------------------------------------------|------------------------|
| `Always`       | Restart the container regardless of exit code.                     | Deployments, plain Pods |
| `OnFailure`    | Restart only if the container exited **non-zero**.                 | Jobs (common)          |
| `Never`        | Never restart; let the Pod reach a terminal phase.                 | one-shot tasks         |

Key consequence: with `restartPolicy: Always`, a container that exits `0` will
still be **restarted**, so the Pod stays `Running` instead of going to
`Succeeded`. To *observe* the `Succeeded`/`Failed` distinction cleanly, use
`restartPolicy: Never`.

---

## 6. Termination & Exit Codes

When a container's main process exits, its **exit code** determines success or
failure:

- **Exit code `0`** → success. With `restartPolicy: Never`/`OnFailure`, the
  container's state becomes `Terminated (reason: Completed)`. If *all* containers
  succeed, the Pod phase becomes **`Succeeded`**.
- **Non-zero exit code** (`1`–`255`) → failure. State becomes
  `Terminated (reason: Error)`. The Pod phase becomes **`Failed`** (with
  `restartPolicy: Never`).

Some non-zero codes have conventional meaning:

| Exit code | Typical meaning                                          |
|-----------|---------------------------------------------------------|
| `0`       | Success                                                  |
| `1`       | General / application error                              |
| `137`     | `128 + 9` → killed by **SIGKILL** (often OOMKilled or a forced `kill`) |
| `139`     | `128 + 11` → **SIGSEGV** (segmentation fault)           |
| `143`     | `128 + 15` → **SIGTERM** (graceful termination signal)  |

> Rule of thumb: a code above `128` usually means the process was killed by a
> signal, and the signal number is `exitCode − 128`.

---

## Demo 1 — Exit code 0 (success)

A container that runs briefly and exits cleanly. With `restartPolicy: Never`, the
Pod reaches the terminal **`Succeeded`** phase.

`pod-success.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-success
spec:
  restartPolicy: Never
  containers:
    - name: worker
      image: busybox
      command: ["sh", "-c", "echo 'doing work...'; sleep 3; echo 'done'; exit 0"]
```

Run it:

```bash
kubectl apply -f pod-success.yaml

# Watch it move Pending → Running → Completed
kubectl get pod pod-success -w
```

Expected `kubectl get pods` output after a few seconds:

```
NAME          READY   STATUS      RESTARTS   AGE
pod-success   0/1     Completed   0          10s
```

Confirm the phase and exit code:

```bash
kubectl get pod pod-success -o jsonpath='{.status.phase}{"\n"}'
# → Succeeded

kubectl get pod pod-success \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
# → 0
```

> Note: `STATUS` column shows **`Completed`** (a synthesized string) while the
> **phase** is **`Succeeded`** — a live example of phase vs status differing.

---

## Demo 2 — Non-zero exit code (failure)

Same idea, but the process exits with code `1`. The Pod reaches **`Failed`**.

`pod-failure.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-failure
spec:
  restartPolicy: Never
  containers:
    - name: worker
      image: busybox
      command: ["sh", "-c", "echo 'trying...'; sleep 2; echo 'oops'; exit 1"]
```

Run it:

```bash
kubectl apply -f pod-failure.yaml
kubectl get pod pod-failure -w
```

Expected output:

```
NAME          READY   STATUS   RESTARTS   AGE
pod-failure   0/1     Error    0          8s
```

Confirm:

```bash
kubectl get pod pod-failure -o jsonpath='{.status.phase}{"\n"}'
# → Failed

kubectl get pod pod-failure \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
# → 1

kubectl get pod pod-failure \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{"\n"}'
# → Error
```

Here the phase is **`Failed`** and the `STATUS` column shows **`Error`**.

---

## Demo 3 — CrashLoopBackOff

This demonstrates the trickiest phase-vs-status case: a Pod stuck **`Running`**
while its container keeps failing. Uses the default `restartPolicy: Always`.

`pod-crashloop.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-crashloop
spec:
  restartPolicy: Always
  containers:
    - name: worker
      image: busybox
      command: ["sh", "-c", "echo 'starting'; sleep 2; exit 1"]
```

Run it and watch the restart count climb:

```bash
kubectl apply -f pod-crashloop.yaml
kubectl get pod pod-crashloop -w
```

Expected output over time:

```
NAME            READY   STATUS             RESTARTS   AGE
pod-crashloop   0/1     Running            0          3s
pod-crashloop   0/1     Error              1          5s
pod-crashloop   0/1     CrashLoopBackOff   1          7s
pod-crashloop   0/1     CrashLoopBackOff   3          60s
```

Now the punchline — the **phase** stays `Running` even though the container is
clearly broken:

```bash
kubectl get pod pod-crashloop -o jsonpath='{.status.phase}{"\n"}'
# → Running   ← phase says Running...

kubectl get pod pod-crashloop \
  -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{"\n"}'
# → CrashLoopBackOff   ← ...but status tells the truth
```

Each restart uses **exponential backoff** (10s, 20s, 40s … capped at 5 min),
which is why the container waits longer between attempts as failures pile up.

---

## Inspecting exit codes yourself

Handy commands for any Pod:

```bash
# Full human-readable status, events, and the last exit code
kubectl describe pod <name>

# Just the exit code of the (first) container
kubectl get pod <name> \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'

# Exit code of the LAST run (useful after a restart)
kubectl get pod <name> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'

# Logs from a previous (crashed) instance
kubectl logs <name> --previous
```

Clean up all demos:

```bash
kubectl delete pod pod-success pod-failure pod-crashloop --ignore-not-found
```

---

## Quick Reference

| Situation                          | restartPolicy | Exit code | Phase       | STATUS column      |
|------------------------------------|---------------|-----------|-------------|--------------------|
| Container finishes cleanly         | `Never`       | `0`       | `Succeeded` | `Completed`        |
| Container errors out               | `Never`       | non-zero  | `Failed`    | `Error`            |
| Container errors, keeps restarting | `Always`      | non-zero  | `Running`   | `CrashLoopBackOff` |
| Container finishes cleanly         | `Always`      | `0`       | `Running`   | `Completed`→restart|
| OOM killed                         | any           | `137`     | varies      | `OOMKilled`        |

### The three things to remember

1. **Phase** = one of 5 coarse words (`Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`), stored in `.status.phase`.
2. **Status** = the whole picture, including per-container states and the `STATUS` column you see in `kubectl get pods` — which is *synthesized*, not the phase.
3. **Exit `0` → Succeeded, non-zero → Failed** — but only when `restartPolicy` lets the Pod actually terminate (`Never` / `OnFailure`). With `Always`, a failing container loops in `CrashLoopBackOff` while the phase stays `Running`.
