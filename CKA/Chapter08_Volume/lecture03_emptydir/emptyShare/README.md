# Two nginx Containers in One Pod — NodePort + Shared CSS via emptyDir

## Overview

- One Pod (`two-nginx-pod`) running **two nginx containers**:
  - `nginx-one` → listens on port **80**, exposed on NodePort **30081**
  - `nginx-two` → listens on port **8080**, exposed on NodePort **30082**
- Each container serves its **own HTML file** (different output).
- One **CSS file** is shared by both containers through an **emptyDir** volume
  mounted at `/usr/share/nginx/html/css` in both.

> Containers in a pod share the same network, so both can't use port 80.
> That's why `nginx-two` is switched to port 8080 at startup.

## Files

| File              | Purpose                                         |
|-------------------|-------------------------------------------------|
| `pod.yaml`        | Pod with 2 nginx containers + emptyDir volume   |
| `services.yaml`   | Two NodePort services (one per container)       |
| `container1.html` | Page for `nginx-one`                            |
| `container2.html` | Page for `nginx-two`                            |
| `style.css`       | Shared stylesheet (copied into the emptyDir)    |

---

## 1. Create the Pod and Services

```bash
kubectl apply -f pod.yaml
kubectl apply -f services.yaml

kubectl get pod two-nginx-pod -o wide
kubectl get svc nginx-one-svc nginx-two-svc
```

Wait until the pod shows `2/2 Running`.

---

## 2. Copy the HTML file into each container

Each HTML file is copied as `index.html` into its own container.

**Container 1 (`nginx-one`):**
```bash
kubectl cp container1.html two-nginx-pod:/usr/share/nginx/html/index.html -c nginx-one
```

**Container 2 (`nginx-two`):**
```bash
kubectl cp container2.html two-nginx-pod:/usr/share/nginx/html/index.html -c nginx-two
```

---

## 3. Copy the CSS file into the shared emptyDir

Copy it into **only one** container — it appears in both because the volume is shared.

```bash
kubectl cp style.css two-nginx-pod:/usr/share/nginx/html/css/style.css -c nginx-one
```

Verify it is visible from **both** containers:
```bash
kubectl exec two-nginx-pod -c nginx-one -- ls -l /usr/share/nginx/html/css
kubectl exec two-nginx-pod -c nginx-two -- ls -l /usr/share/nginx/html/css
```

---

## 4. Access the pages

```bash
# Get a node IP
kubectl get nodes -o wide

curl http://<NODE-IP>:30081     # -> Container 1 page
curl http://<NODE-IP>:30082     # -> Container 2 page
curl http://<NODE-IP>:30081/css/style.css   # same CSS from both
curl http://<NODE-IP>:30082/css/style.css
```

On **minikube**:
```bash
minikube service nginx-one-svc --url
minikube service nginx-two-svc --url
```

Open both in a browser: different text and background color per container, same shared stylesheet.

---

## 5. Show the mount path INSIDE the containers

```bash
# Mount entries for the emptyDir
kubectl exec two-nginx-pod -c nginx-one -- sh -c "mount | grep /usr/share/nginx/html/css"
kubectl exec two-nginx-pod -c nginx-two -- sh -c "mount | grep /usr/share/nginx/html/css"

# Disk/filesystem backing the mount
kubectl exec two-nginx-pod -c nginx-one -- df -h /usr/share/nginx/html/css
kubectl exec two-nginx-pod -c nginx-two -- df -h /usr/share/nginx/html/css

# Mount path as defined in the pod spec
kubectl get pod two-nginx-pod -o jsonpath='{range .spec.containers[*]}{.name}{" -> "}{.volumeMounts[*].mountPath}{"\n"}{end}'

# Proof of sharing: create a file in one container, read it from the other
kubectl exec two-nginx-pod -c nginx-two -- sh -c "echo 'hello from nginx-two' > /usr/share/nginx/html/css/test.txt"
kubectl exec two-nginx-pod -c nginx-one -- cat /usr/share/nginx/html/css/test.txt
```

---

## 6. Show the mount path ON THE NODE

emptyDir data lives on the node at:
```
/var/lib/kubelet/pods/<POD-UID>/volumes/kubernetes.io~empty-dir/<VOLUME-NAME>
```

**Step 1 — find the node and Pod UID:**
```bash
kubectl get pod two-nginx-pod -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl get pod two-nginx-pod -o jsonpath='{.metadata.uid}{"\n"}'
```

**Step 2 — log in to that node:**
```bash
ssh <user>@<NODE-IP>       # regular cluster
minikube ssh               # minikube
docker exec -it <kind-node-name> bash   # kind
```

**Step 3 — on the node, list the emptyDir:**
```bash
sudo ls -l /var/lib/kubelet/pods/<POD-UID>/volumes/kubernetes.io~empty-dir/shared-css/
sudo cat   /var/lib/kubelet/pods/<POD-UID>/volumes/kubernetes.io~empty-dir/shared-css/style.css

# Or find it without knowing the UID
sudo find /var/lib/kubelet/pods -type d -name shared-css
```

You will see `style.css` (and `test.txt`) — the same files both containers see.

---

## 7. Cleanup

```bash
kubectl delete -f services.yaml
kubectl delete -f pod.yaml
```

> Note: emptyDir is deleted when the pod is deleted, and the copied `index.html`
> files live in the container filesystem — they are lost if a container restarts.
> Re-run steps 2 and 3 after any restart.
