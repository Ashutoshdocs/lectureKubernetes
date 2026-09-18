# Kubernetes Practical 03 — Where an `emptyDir` Volume Lives on the Host

This Pod (`nginx-emptydir-pod`) mounts an `emptyDir` volume at
`/usr/share/nginx/html` **inside the container**. But where does that data
actually sit **on the node**? This guide shows how to find and verify it.

## Quick answer — the host path

An `emptyDir` is stored on the node's local disk, under the kubelet directory:

```
/var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~empty-dir/<VOLUME_NAME>/
```

For this Pod the volume name is `nginx-html`, so:

```
/var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~empty-dir/nginx-html/
```

You need the Pod's UID (not its name) and access to the node's filesystem
(`minikube ssh`, or SSH into the node) to see it.

---

## Step 1 — Deploy the Pod

```bash
kubectl apply -f nginx-emptydir-pod.yaml
kubectl get pod nginx-emptydir-pod -o wide     # note the NODE the pod runs on
```

## Step 2 — Get the Pod UID and build the exact host path

```bash
# UID of the pod
kubectl get pod nginx-emptydir-pod -o jsonpath='{.metadata.uid}{"\n"}'

# Build the full host path in one go
POD_UID=$(kubectl get pod nginx-emptydir-pod -o jsonpath='{.metadata.uid}')
echo "/var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~empty-dir/nginx-html/"
```

## Step 3 — Look at the directory ON THE NODE

### Minikube

```bash
minikube ssh
# inside the node:
sudo ls -l /var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~empty-dir/nginx-html/
```

### A real cluster (kubeadm / cloud node)

```bash
# Step 1 showed which NODE the pod is on. SSH into that node, then:
sudo ls -l /var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~empty-dir/nginx-html/
```

It will be empty at first — `emptyDir` starts empty.

---

## Step 4 — Prove the container path and the host path are the SAME directory

Write a file through the container, then read it from the host.

```bash
# 1) Create a file inside the container's mount
kubectl exec -it nginx-emptydir-pod -- sh -c 'echo "hello from the container" > /usr/share/nginx/html/index.html'

# 2) Read the SAME file directly on the node (minikube ssh, or on the node)
sudo cat /var/lib/kubelet/pods/$POD_UID/volumes/kubernetes.io~empty-dir/nginx-html/index.html
# -> hello from the container
```

Same bytes in both places = it's one directory, exposed on the host and bind-mounted
into the container.

## Step 5 — Confirm the mount from inside the container (optional)

```bash
kubectl exec -it nginx-emptydir-pod -- df -h /usr/share/nginx/html
kubectl exec -it nginx-emptydir-pod -- mount | grep nginx
```

---

## Cleanup

```bash
kubectl delete -f nginx-emptydir-pod.yaml
```

After the Pod is deleted, the kubelet removes
`/var/lib/kubelet/pods/<POD_UID>/...` — **the `emptyDir` data is gone.**

---

## Notes / how `emptyDir` behaves

- **Lifecycle:** created when the Pod is assigned to a node, deleted permanently
  when the Pod is removed from the node. It survives container restarts within the
  same Pod, but **not** Pod deletion or rescheduling to another node.
- **Storage medium:** with `emptyDir: {}` (this manifest) it's backed by the node's
  disk at the path above. If you set `emptyDir: { medium: Memory }`, it's a tmpfs
  (RAM) mount instead and is **not** written to that disk path.
- **Per-node:** the path exists only on the node running the Pod. On multi-node
  clusters, first find the node with `kubectl get pod ... -o wide`.
- **Root needed:** `/var/lib/kubelet` is root-owned, so use `sudo`.
- **Custom kubelet root:** if the cluster runs kubelet with `--root-dir`, replace
  `/var/lib/kubelet` with that directory.
