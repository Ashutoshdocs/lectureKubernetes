# hostPath vs emptyDir — Proven with a Demo

Both mount into a pod at `/data`. They look identical until you delete the pod.
This demo makes the two real differences visible:

> - **emptyDir** lives and dies with the **pod**, and is **private** to it.
> - **hostPath** lives on the **node**, **survives** the pod, and is **shared**
>   by any pod that lands on that node.

| | `emptyDir` | `hostPath` |
|---|---|---|
| Backed by | kubelet-managed temp dir on the node | a **specific** directory on the node you choose |
| Lifecycle | tied to the **pod** — deleted when the pod is removed | tied to the **node** — persists after the pod is gone |
| Survives pod delete? | ❌ no | ✅ yes (if a new pod lands on the same node) |
| Shared between pods? | ❌ no (each pod gets its own) | ✅ yes (any pod mounting the same path) |
| You pick the path? | ❌ no | ✅ yes (`spec.hostPath.path`) |
| Survives container **restart** (same pod)? | ✅ yes | ✅ yes |
| Typical use | scratch space, cache, sharing between containers **in one pod** | node-level data, node agents, learning/single-node |
| Production caveat | fine, it's meant to be ephemeral | node-bound + a security risk; avoid for app data (use a PV/CSI) |

---

## Files
```
k8s-hostpath-vs-emptydir/
├── README.md
├── demo.sh                 # up / emptydir / hostpath / clean
├── 00-namespace.yaml
├── 10-emptydir-pod.yaml    # pod with an emptyDir volume
├── 20-hostpath-pod.yaml    # pod with a hostPath volume
└── 21-hostpath-pod2.yaml   # 2nd pod, SAME host path -> proves sharing
```

## Prerequisites
`kubectl` + any cluster. A single-node kind / minikube / Docker Desktop is ideal
(hostPath is node-local, so single-node keeps the proof simple).

## Fastest path
```bash
chmod +x demo.sh
./demo.sh up
./demo.sh emptydir     # watch the data vanish
./demo.sh hostpath     # watch the data survive + be shared
./demo.sh clean
```

The manual walkthrough with the proof output is below.

---

## Step 1 — Deploy
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-emptydir-pod.yaml
kubectl apply -f 20-hostpath-pod.yaml
kubectl apply -f 21-hostpath-pod2.yaml
kubectl -n vol-demo wait --for=condition=Ready pod --all --timeout=120s
kubectl -n vol-demo get pods -o wide
```

## Step 2 — emptyDir: data dies with the pod ❌

Write a file inside the pod:
```bash
kubectl -n vol-demo exec emptydir-pod -- sh -c 'echo "scratch data $(date -u)" > /data/file.txt'
kubectl -n vol-demo exec emptydir-pod -- cat /data/file.txt
```

Delete the pod and recreate it from the same YAML:
```bash
kubectl -n vol-demo delete pod emptydir-pod
kubectl apply -f 10-emptydir-pod.yaml
kubectl -n vol-demo wait --for=condition=Ready pod/emptydir-pod --timeout=60s
```

**✅ Proof — the file is gone:**
```bash
kubectl -n vol-demo exec emptydir-pod -- ls -l /data
kubectl -n vol-demo exec emptydir-pod -- cat /data/file.txt || echo "GONE (expected)"
```
```
total 0
cat: can't open '/data/file.txt': No such file or directory
GONE (expected)
```
The emptyDir was destroyed together with the old pod and recreated **empty**.

> Nuance: an emptyDir survives a **container** crash/restart within the *same*
> pod. It's the **pod** deletion (reschedule, `kubectl delete pod`, node
> failure) that wipes it.

## Step 3 — hostPath: data survives and is shared ✅

Write a file inside `hostpath-pod`:
```bash
kubectl -n vol-demo exec hostpath-pod -- sh -c 'echo "node data $(date -u)" > /data/file.txt'
kubectl -n vol-demo exec hostpath-pod -- cat /data/file.txt
```

**✅ Proof A — sharing:** a *different* pod on the same node sees it:
```bash
kubectl -n vol-demo exec hostpath-pod2 -- cat /data/file.txt
```
`hostpath-pod2` never wrote anything, yet it reads the same file — because both
mount `/mnt/data/hostpath-demo` on the node.

Now delete `hostpath-pod` and recreate it:
```bash
kubectl -n vol-demo delete pod hostpath-pod
kubectl apply -f 20-hostpath-pod.yaml
kubectl -n vol-demo wait --for=condition=Ready pod/hostpath-pod --timeout=60s
```

**✅ Proof B — persistence:** the file is still there:
```bash
kubectl -n vol-demo exec hostpath-pod -- cat /data/file.txt
```
Same content as before the delete. The data lives on the **node**, not the pod.

**✅ Proof C — it's a real node path (the "outside"):**
```bash
NODE=$(kubectl -n vol-demo get pod hostpath-pod -o jsonpath='{.spec.nodeName}')
# kind (node = a docker container):
docker exec "$NODE" ls -l /mnt/data/hostpath-demo
docker exec "$NODE" cat  /mnt/data/hostpath-demo/file.txt
# minikube:
minikube ssh -- 'sudo ls -l /mnt/data/hostpath-demo'
```
You can read/write the file straight from the node — that's the defining trait of
hostPath.

## Step 4 — See how each is mounted
```bash
kubectl -n vol-demo exec emptydir-pod -- sh -c 'cat /proc/mounts | grep /data'
kubectl -n vol-demo exec hostpath-pod -- sh -c 'cat /proc/mounts | grep /data'
```
Both show up as a bind mount of the node fs, but the **source directory** differs:
emptyDir points into kubelet's `.../pods/<uid>/volumes/kubernetes.io~empty-dir/...`
(auto-managed, deleted with the pod), while hostPath points to the exact
`/mnt/data/hostpath-demo` you chose.

---

## Takeaways
- Reach for **emptyDir** when you want fast, throwaway scratch space, or to share
  files **between containers of the same pod**. Don't expect it to outlive the pod.
- Reach for **hostPath** only when a pod genuinely needs a node's own files (node
  monitoring agents, `/var/run/docker.sock`, single-node learning). For real app
  data that must survive rescheduling across nodes, use a **PVC backed by a PV /
  CSI driver**, not hostPath — hostPath ties you to one node and is a common
  security finding.

## Cleanup
```bash
./demo.sh clean
# or
kubectl delete namespace vol-demo
```
