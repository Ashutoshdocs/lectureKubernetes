# Kubernetes `restartPolicy` & "What happens when it dies?" — Hands‑On Lab

The most common Kubernetes misconception is that `restartPolicy` decides whether
a **pod** comes back. It doesn't. This lab pulls apart the two separate
machines that make things "come back to life," then shows exactly what each
controller does when its pod dies.

By the end you will be able to:

- State what `restartPolicy` actually controls (and what it doesn't).
- Predict the outcome for every `restartPolicy` × exit‑code combination.
- Explain the difference between a **container restart** and a **pod replacement**.
- Say precisely what happens when a pod dies under a ReplicaSet, Deployment,
  DaemonSet, and StatefulSet — including which keep the pod's name.

---

## 1. The one idea that fixes all the confusion

There are **two independent mechanisms**, run by two different components:

| | **Container restart** | **Pod replacement** |
|---|---|---|
| Run by | the **kubelet** (on the node) | a **controller** (RS / Deployment / DaemonSet / StatefulSet / Job) |
| Triggered by | a container process **exiting** | a whole **pod disappearing** (deleted, node lost) |
| Governed by | `spec.restartPolicy` | the controller's desired state |
| What it produces | the same container running again, **same pod, same name** | a **new pod** to satisfy desired state |
| Creates new pods? | **Never** | **Yes** |

`restartPolicy` lives entirely in the left column. It restarts *containers
inside an existing pod, in place*. It cannot bring back a pod that was deleted,
and it has nothing to do with controllers replacing pods. Keep this table in
your head and everything below is obvious.

---

## 2. `restartPolicy` values × exit code (Demos in `01`/`02`)

`restartPolicy` (a pod‑level field) takes three values. Their effect depends on
**how the container exited**:

| restartPolicy | Container exits **0** (success) | Container exits **non‑zero** (failure) |
|---|---|---|
| `Always` (default) | Restarted anyway | Restarted → repeated crashes = `CrashLoopBackOff` |
| `OnFailure` | Not restarted → pod `Completed` | Restarted |
| `Never` | Not restarted → pod `Completed` | Not restarted → pod `Failed` |

`01-restartpolicy-exit1.yaml` and `02-restartpolicy-exit0.yaml` create one pod
per row so you can watch every cell of this table happen.

**About `CrashLoopBackOff`:** it's a *status*, not an error type. When a
container keeps crashing, the kubelet waits longer between each restart —
roughly 10s, 20s, 40s… doubling up to a 5‑minute cap — and reports
`CrashLoopBackOff` while it waits. The counter resets after the container has
run cleanly for ~10 minutes.

```bash
kubectl apply -f 01-restartpolicy-exit1.yaml
kubectl apply -f 02-restartpolicy-exit0.yaml
kubectl get pods -w --show-labels
kubectl describe pod always-fail | grep -A5 "State\|Restart Count"
```

---

## 3. Where each `restartPolicy` value is even allowed

You can't put any value anywhere. Validation depends on the workload type:

| Workload | Allowed `restartPolicy` |
|---|---|
| Bare **Pod** | `Always`, `OnFailure`, `Never` |
| **Deployment / ReplicaSet / DaemonSet / StatefulSet** | **`Always` only** (default) |
| **Job / CronJob** | **`OnFailure` or `Never`** (not `Always`) |

The long‑running controllers force `Always` because their job is to keep
something running forever; finite Jobs forbid `Always` because a job is meant to
end. Try setting `restartPolicy: Never` in `03-replicaset.yaml` and re‑applying
— the API server rejects it with an "Unsupported value" error. That rejection
*is* the lesson.

---

## 4. Files

| File | Shows |
|---|---|
| `01-restartpolicy-exit1.yaml` | `restartPolicy` on a **failing** container (exit 1) |
| `02-restartpolicy-exit0.yaml` | `restartPolicy` on a **succeeding** container (exit 0) |
| `03-replicaset.yaml` | Pod death under a **ReplicaSet** → replacement pod |
| `04-deployment.yaml` | Pod death under a **Deployment** (via its ReplicaSet) |
| `05-daemonset.yaml` | Pod death under a **DaemonSet** → replaced on the same node |
| `06-statefulset.yaml` | Pod death under a **StatefulSet** → same name + same volume |

---

## 5. Prerequisites

- A test cluster (`minikube`, `kind`, k3s…) and `kubectl`.
- For the StatefulSet demo: a **default StorageClass** (kind and minikube both
  ship one named `standard`; check with `kubectl get storageclass`).

---

## 6. Demo — a **container** dies (`01`, `02`)

Covered above. The headline: the pod keeps its name and node; only the container
is restarted (or not), and the `RESTARTS` count is your evidence.

```bash
kubectl get pods -w -l demo=restart-exit1
kubectl get pod always-fail -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

---

## 7. Demo — a bare **pod** dies

A bare pod has no controller behind it.

```bash
kubectl run solo --image=nginx:1.27 --restart=Never
kubectl delete pod solo
kubectl get pod solo          # Error from server (NotFound) - gone for good
```

Nothing recreates it. `restartPolicy` can't help here — that only governs the
*container*, and there's no pod left to hold one. This is exactly why you almost
never run bare pods in production: wrap them in a controller.

---

## 8. Demo — a pod under a **ReplicaSet** dies (`03`)

```bash
kubectl apply -f 03-replicaset.yaml
kubectl get pods -l app=nginx-rs -o wide
kubectl delete pod <one-of-them>
kubectl get pods -l app=nginx-rs -o wide -w
```

The ReplicaSet sees "2 pods, want 3" and creates a **new** pod with a **new
random name** (and possibly a different node) to restore the count. The deleted
pod is not restarted — it's replaced.

---

## 9. Demo — a pod under a **Deployment** dies (`04`)

```bash
kubectl apply -f 04-deployment.yaml
kubectl get deploy,rs,pods -l app=nginx-deploy
kubectl delete pod <one-of-them>
kubectl get pods -l app=nginx-deploy -w
```

Same replacement behaviour as a ReplicaSet — because a Deployment *is* a manager
of ReplicaSets. The ownership chain is **Deployment → ReplicaSet → Pod**, and
it's the ReplicaSet layer that recreates the pod. The Deployment adds the extra
powers (rolling updates, rollbacks, revision history) on top.

---

## 10. Demo — a pod under a **DaemonSet** dies (`05`)

```bash
kubectl apply -f 05-daemonset.yaml
kubectl get pods -l app=nginx-ds -o wide      # note the NODE
kubectl delete pod <the-pod>
kubectl get pods -l app=nginx-ds -o wide -w   # new pod, SAME node
```

A DaemonSet targets **nodes**, not a replica count. The replacement lands back
on the **same node**, because that node still needs its one copy. (On multi‑node
clusters, that's also why scaling is done by adding/removing nodes, not
replicas.)

---

## 11. Demo — a pod under a **StatefulSet** dies (`06`)

```bash
kubectl apply -f 06-statefulset.yaml
kubectl get pods -l app=nginx-sts -o wide     # web-0, web-1, web-2 (created in order)
kubectl get pvc                                # data-web-0/1/2
kubectl delete pod web-1
kubectl get pods -l app=nginx-sts -w           # comes back AS web-1
kubectl get pvc                                # data-web-1 was REUSED
```

The replacement keeps the **same ordinal name** (`web-1`) and **reattaches the
same PersistentVolumeClaim** (`data-web-1`). Stable identity is the whole point
of a StatefulSet — it's what lets databases and clustered apps survive a pod
death without losing their data or their place in the cluster.

Prove the storage persisted:

```bash
kubectl exec web-1 -- sh -c 'echo hello > /usr/share/nginx/html/index.html'
kubectl delete pod web-1
# after it restarts:
kubectl exec web-1 -- cat /usr/share/nginx/html/index.html   # -> hello
```

---

## 12. Master reference — "what happens when ___ dies?"

| What dies | Who reacts | What you get | Same name? |
|---|---|---|---|
| Container process exits | kubelet (`restartPolicy`) | container restarted in place | ✅ yes |
| Container crashes repeatedly | kubelet backoff | `CrashLoopBackOff` | ✅ yes |
| Bare **Pod** deleted | nobody | gone forever | — |
| Pod under **ReplicaSet** | ReplicaSet | new replacement pod | ❌ new |
| Pod under **Deployment** | Deployment → RS | new replacement pod | ❌ new |
| Pod under **DaemonSet** | DaemonSet | new pod on the **same node** | ❌ new |
| Pod under **StatefulSet** | StatefulSet | recreated with **same name + PVC** | ✅ yes |

---

## 13. Bonus — when the whole **node** dies

Container restart can't help here (the node hosting the kubelet is gone), so
only controllers save you:

- **Bare pod:** lost permanently.
- **ReplicaSet / Deployment:** after the node is declared unreachable
  (a few minutes by default), replacements are scheduled on **other** nodes.
- **DaemonSet:** waits — it only wants a pod *per node*, so it does nothing until
  a healthy node exists to place one on.
- **StatefulSet:** deliberately cautious. It won't spin up `web-1` elsewhere
  while the old `web-1` might still be running on the unreachable node (that
  could corrupt shared storage). Recovery may need the node/pod to be forcibly
  removed first.

---

## 14. Gotchas & troubleshooting

- **"`restartPolicy: Never` but my pod came back!"** It was under a controller.
  The controller replaced the *pod*; `restartPolicy` only ever governed the
  *container*.
- **Deployment rejected: "Unsupported value: Never".** Long‑running controllers
  require `Always`. Use a Job if you want `OnFailure`/`Never`.
- **`CrashLoopBackOff` is not a crash cause.** It just means "crashing and I'm
  waiting before the next try." Find the real reason in
  `kubectl logs <pod> --previous` and `kubectl describe pod`.
- **StatefulSet pods stuck `Pending`.** Usually no default StorageClass — the
  PVCs can't bind. `kubectl get pvc` and `kubectl get storageclass`.
- **DaemonSet pod never schedules on a single node.** Your only node is a tainted
  control‑plane node; uncomment the toleration in `05-daemonset.yaml`.
- **Advanced aside:** recent Kubernetes versions also allow a *per‑container*
  `restartPolicy: Always` on an init container to implement native **sidecars** —
  a narrow exception to the "restartPolicy is pod‑level" rule.

---

## 15. Clean up

```bash
kubectl delete -f 06-statefulset.yaml --ignore-not-found
kubectl delete pvc -l app=nginx-sts   # StatefulSet PVCs are NOT auto-deleted
kubectl delete -f 05-daemonset.yaml   --ignore-not-found
kubectl delete -f 04-deployment.yaml  --ignore-not-found
kubectl delete -f 03-replicaset.yaml  --ignore-not-found
kubectl delete -f 02-restartpolicy-exit0.yaml --ignore-not-found
kubectl delete -f 01-restartpolicy-exit1.yaml --ignore-not-found
kubectl delete pod solo --ignore-not-found
```

> Note: deleting a StatefulSet leaves its PVCs behind on purpose (your data is
> precious). Remove them explicitly as shown.

---

### One‑line summary to leave students with

> `restartPolicy` is the **kubelet** restarting a **container** in place; a
> **controller** replacing a whole **pod** is a different thing entirely — and
> which controller you chose decides whether the replacement keeps its name
> (StatefulSet: yes; ReplicaSet/Deployment/DaemonSet: no), its node (DaemonSet:
> yes), and its data (StatefulSet: yes).
