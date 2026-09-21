# Kubernetes Practical 02 — ConfigMap & Secret as Mounted Volumes (Live Frontend)

Here the ConfigMap and Secret are mounted into the Pod as **files** (a volume),
not as environment variables. The big difference from Practical 01:

> **Volume-mounted ConfigMaps and Secrets update automatically** in a running pod
> (after a short kubelet sync, usually up to ~60s). **No pod restart needed.**

The container regenerates its web page from the mounted files every few seconds,
and the browser auto-refreshes — so when you edit the ConfigMap the page **flips
its theme live** (e.g. dark → light).

## Files

| File | Purpose |
|------|---------|
| `mount-demo-pod.yaml` | Pod mounting `web-config` and `db-secret` as volumes; renders a live page |
| `mount-demo-service.yaml` | NodePort Service to open the page in a browser |
| `README.md` | This guide |

---

## Step 1 — (Optional) Update the Practical-01 ConfigMap/Secret via dry-run + apply

```bash
# --dry-run=client prints YAML instead of creating directly; pipe to apply to update in place
kubectl create configmap my-config \
  --from-literal=APP_COLOR=red --from-literal=APP_MODE=staging \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl create secret generic my-secret \
  --from-literal=DB_USER=root --from-literal=DB_PASS=New@123 \
  -o yaml --dry-run=client | kubectl apply -f -
```

## Step 2 — Create the ConfigMap & Secret used by this pod

```bash
# ConfigMap with app settings
kubectl create configmap web-config \
  --from-literal=theme=dark \
  --from-literal=title="My Web App"

# Secret with DB credentials
kubectl create secret generic db-secret \
  --from-literal=username=admin \
  --from-literal=password=Pass@123
```

## Step 3 — Deploy the Pod and the Service

```bash
kubectl apply -f mount-demo-pod.yaml
kubectl apply -f mount-demo-service.yaml

kubectl get pod mount-demo
kubectl get svc mount-demo-svc
```

## Step 4 — Open the frontend in a browser

```bash
# Minikube
minikube service mount-demo-svc --url
# or:  http://<minikube-ip>:30081     (minikube ip)

# Any other cluster
kubectl get nodes -o wide
# open:  http://<node-ip>:30081
```

You'll see the `theme` and `title` (from the ConfigMap) and `username`/`password`
(from the Secret). A dark theme renders a dark page.

## Step 5 — Inspect the mounted files from inside the pod

```bash
# ConfigMap files
kubectl exec -it mount-demo -- ls /etc/config
kubectl exec -it mount-demo -- cat /etc/config/theme

# Secret files
kubectl exec -it mount-demo -- ls /etc/secret
kubectl exec -it mount-demo -- cat /etc/secret/username
```

---

## Step 6 — Change the ConfigMap and watch it update LIVE (no restart)

```bash
# Edit the ConfigMap: change theme from dark -> light
kubectl edit configmap web-config
```

Now watch the file inside the pod change on its own (give it up to ~60s):

```bash
# Repeat this a few times until it flips to "light"
kubectl exec -it mount-demo -- cat /etc/config/theme
```

Refresh the browser (or just wait — the page auto-refreshes every 5s). The page
switches to the light theme. **You did not restart the pod.**

## Step 7 — Update the Secret the non-disruptive way

```bash
kubectl create secret generic db-secret \
  --from-literal=username=root --from-literal=password=New@456 \
  -o yaml --dry-run=client | kubectl apply -f -

# Confirm it syncs into the pod (secrets mounted as volumes also auto-update)
kubectl exec -it mount-demo -- cat /etc/secret/username
```

The frontend will show the new `username`/`password` after the sync + refresh.

---

## Cleanup

```bash
kubectl delete -f mount-demo-service.yaml
kubectl delete -f mount-demo-pod.yaml
kubectl delete configmap web-config
kubectl delete secret db-secret
```

---

## Notes

- **Env vars vs volumes:** env vars (`valueFrom`) are read only at pod start and
  need a pod recreate to change (Practical 01). **Mounted volumes auto-update** —
  that's what this practical demonstrates.
- **Sync delay:** the kubelet refreshes mounted ConfigMap/Secret files periodically
  (default up to ~1 minute), so changes are near-live, not instant.
- **`subPath` exception:** a file mounted with `subPath` does **not** auto-update.
  This pod mounts whole directories, so updates work.
- A Pod's `command`/labels can't be changed on a running pod. To reapply changes to
  the pod itself: `kubectl delete pod mount-demo` then `kubectl apply -f mount-demo-pod.yaml`.
- **Security:** printing `password` on a page is only for this learning exercise.
- **NodePort range** is `30000–32767`; change `30081` if it clashes.
