# Kubernetes Practical — ConfigMap & Secret as Environment Variables (with a Visual Frontend)

This practical injects values from a **ConfigMap** and a **Secret** into a Pod as
environment variables. Instead of the default nginx page, the container builds an
`index.html` from those variables, so you can **see the values in a browser** — and
the whole page background changes to whatever `APP_COLOR` is set to.

## Files

| File | Purpose |
|------|---------|
| `env-demo-rs.yaml` | ReplicaSet running nginx; renders a page from the env vars |
| `env-demo-service.yaml` | NodePort Service to open the page in a browser |
| `README.md` | This guide |

---

## Step 1 — Create the ConfigMap

```bash
# Create a ConfigMap named "my-config" with two key-value pairs
kubectl create configmap my-config \
  --from-literal=APP_COLOR=blue \
  --from-literal=APP_MODE=production

# View it in YAML format (to verify data)
kubectl get configmap my-config -o yaml
```

## Step 2 — Create the Secret

```bash
# Create a Secret named "my-secret" with sensitive key-value pairs
kubectl create secret generic my-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASS=Pass@123

# View it in YAML format (data will be base64 encoded)
kubectl get secret my-secret -o yaml
```

## Step 3 — Deploy the ReplicaSet and the Service

```bash
kubectl apply -f env-demo-rs.yaml
kubectl apply -f env-demo-service.yaml

# Confirm the pod is Running
kubectl get pods -l app=env-demo
kubectl get svc env-demo-svc
```

## Step 4 — Open the frontend in a browser

```bash
# --- Minikube ---
minikube service env-demo-svc --url
# open the printed URL, OR:
# http://<minikube-ip>:30080     (get it with: minikube ip)

# --- Any other cluster (bare node) ---
kubectl get nodes -o wide        # note a node's INTERNAL/EXTERNAL IP
# then open: http://<node-ip>:30080
```

You should see a card showing `APP_COLOR`, `APP_MODE`, `DB_USER`, `DB_PASS`,
with the page background matching the color.

## Step 5 — Verify the env vars from inside the pod (optional)

```bash
# Get the pod name first
kubectl get pods -l app=env-demo

# Show only the relevant variables
kubectl exec -it <podname> -- env | grep -E 'COLOR|MODE|DB'
```

---

## Step 6 — Update the ConfigMap & Secret, then SEE the change

> **Important:** Environment variables are read **only when the Pod starts.**
> Changing a ConfigMap/Secret does **not** update a running Pod. You must
> recreate the Pod (the ReplicaSet immediately makes a new one).

```bash
# Update the ConfigMap (blue -> red, production -> staging)
kubectl create configmap my-config \
  --from-literal=APP_COLOR=red \
  --from-literal=APP_MODE=staging \
  --dry-run=client -o yaml | kubectl apply -f -

# Update the Secret (new credentials)
kubectl create secret generic my-secret \
  --from-literal=DB_USER=root \
  --from-literal=DB_PASS=New@123 \
  --dry-run=client -o yaml | kubectl apply -f -

# Recreate the pod so the new values are picked up.
# The ReplicaSet automatically starts a fresh pod.
kubectl delete pod -l app=env-demo

# Wait for the new pod, then refresh the browser (Ctrl/Cmd + Shift + R).
kubectl get pods -l app=env-demo -w
```

Refresh the page — the background is now **red**, the badge reads **STAGING**, and
the DB credentials show the new values. That's the ConfigMap/Secret change made
visible on the frontend.

---

## Cleanup

```bash
kubectl delete -f env-demo-service.yaml
kubectl delete -f env-demo-rs.yaml
kubectl delete configmap my-config
kubectl delete secret my-secret
```

---

## Notes

- **Security:** showing `DB_PASS` on a web page is only for this learning exercise.
  Never expose real secrets in a UI or in application output.
- **Why recreate the pod?** `valueFrom` env vars are resolved at container start.
  (Only ConfigMaps/Secrets mounted as *volumes* auto-refresh, and even then the app
  must re-read the file.)
- **NodePort range** is `30000–32767`; change `nodePort: 30080` if it's taken.
- Works with `nginx` or `nginx:alpine` — both include `/bin/sh` and `cat`.
