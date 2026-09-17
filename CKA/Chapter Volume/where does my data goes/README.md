# Container filesystem vs. Kubernetes shared volume

This demo runs **one pod with two containers** (`writer` and `reader`) and proves
that:

- A path backed only by a **container's own filesystem** (its writable layer) is
  **private** to that container.
- A path backed by a **pod-level Kubernetes volume** (here an `emptyDir` named
  `shared-data`, mounted into both containers at `/shared`) is **shared** between
  the containers.

| Path       | Backed by                         | Shared between containers? |
|------------|-----------------------------------|----------------------------|
| `/private` | each container's own layer        | ❌ No                      |
| `/shared`  | pod-level `emptyDir` volume       | ✅ Yes                     |

---

## 1. Deploy

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/volume-demo
```

Get the pod name into a variable for convenience:

```bash
POD=$(kubectl get pod -l app=volume-demo -o jsonpath='{.items[0].metadata.name}')
echo "$POD"
```

---

## 2. Prove the container filesystem is NOT shared

Write a file to `/private` **inside the `writer` container**:

```bash
kubectl exec "$POD" -c writer -- sh -c 'mkdir -p /private && echo "written by writer" > /private/note.txt'
```

Confirm it exists in `writer`:

```bash
kubectl exec "$POD" -c writer -- cat /private/note.txt
# -> written by writer
```

Now look for it in the `reader` container:

```bash
kubectl exec "$POD" -c reader -- cat /private/note.txt
# -> cat: can't open '/private/note.txt': No such file or directory
```

**Result:** the `reader` container cannot see it. Each container has its own
isolated filesystem layer — a "container volume" (the container's own writable
layer) is not shared with sibling containers, even inside the same pod.

---

## 3. Prove the Kubernetes shared volume IS shared

Write a file to `/shared` **inside the `writer` container**:

```bash
kubectl exec "$POD" -c writer -- sh -c 'echo "hello from writer" > /shared/message.txt'
```

Read it back from the **`reader` container**:

```bash
kubectl exec "$POD" -c reader -- cat /shared/message.txt
# -> hello from writer
```

Write from the reader too, to show it works both ways:

```bash
kubectl exec "$POD" -c reader -- sh -c 'echo "hello back from reader" >> /shared/message.txt'
kubectl exec "$POD" -c writer -- cat /shared/message.txt
# -> hello from writer
# -> hello back from reader
```

**Result:** both containers read and write the same files under `/shared`,
because that path is backed by one pod-level `emptyDir` volume mounted into both.

---

## 4. Why they differ

- The container filesystem (`/private`) is part of each container's image +
  writable layer. It is created and destroyed with that individual container and
  is never visible to another container.
- A Kubernetes volume like `emptyDir` is declared **once at the pod level** and
  mounted into each container that asks for it. It shares the pod's lifetime, so
  any container mounting it sees the same data.

> Note: an `emptyDir` lives as long as the **pod**. If the pod is deleted (or
> rescheduled to another node), its data is gone. For persistence beyond the pod,
> use a `PersistentVolumeClaim` instead — but the shared-vs-private behavior above
> is identical.

---

## 5. Inspect the service account mount on the host

Every pod automatically gets a **projected volume** mounted at
`/run/secrets/kubernetes.io/serviceaccount` (the SA token, CA cert, and
namespace). Here's how to see it inside the container and then trace it to where
kubelet backs it on the host node.

Confirm the mount inside the container:

```bash
kubectl exec "$POD" -c writer -- cat /proc/mounts | grep serviceaccount
# -> tmpfs /run/secrets/kubernetes.io/serviceaccount tmpfs ro,relatime ...
```

Find the pod UID and the node it runs on (both needed to locate it on the host):

```bash
POD_UID=$(kubectl get pod "$POD" -o jsonpath='{.metadata.uid}')
NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')
echo "uid=$POD_UID node=$NODE"
```

On the node, the projected SA volume lives under kubelet's per-pod directory:

```
/var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~projected/
```

List it on the host. Pick the command matching your cluster:

```bash
# minikube
minikube ssh -- "sudo ls -l /var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~projected/"

# kind (node is a docker container named after $NODE)
docker exec "$NODE" ls -l /var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~projected/

# generic node reachable over SSH
ssh "$NODE" sudo ls -l /var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~projected/
```

You'll see a directory like `kube-api-access-xxxxx/` containing `token`,
`ca.crt`, and `namespace` — the host-side source that kubelet bind-mounts into
the container at `/run/secrets/kubernetes.io/serviceaccount`.

---

## 6. Clean up

```bash
kubectl delete -f deployment.yaml
```
