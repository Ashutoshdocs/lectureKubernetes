# Kubernetes ServiceAccount Demo: Read Pod B's Logs from Inside Pod A

This guide creates a **ServiceAccount (SA)**, a **Role**, and a **RoleBinding**, attaches the SA to **Pod A**, and creates **Pod B** without a custom ServiceAccount. Pod A will then read Pod B's logs from inside the container using the Kubernetes API.

```
+-------------------- namespace: sa-demo --------------------+
|                                                            |
|  ServiceAccount: log-reader-sa                             |
|        |                                                   |
|  RoleBinding: log-reader-binding ---> Role: pod-log-reader |
|        |                              (get/list pods,      |
|        v                               get pods/log)       |
|  +-----------+      reads logs via API      +-----------+  |
|  |  pod-a    | ---------------------------> |  pod-b    |  |
|  | (has SA)  |                              | (no SA)   |  |
|  +-----------+                              +-----------+  |
+------------------------------------------------------------+
```

> **Note on "Pod B without a ServiceAccount":** Kubernetes always assigns the `default` ServiceAccount to a pod if none is specified. To make Pod B truly carry no credentials, we set `automountServiceAccountToken: false`, so no token is mounted into Pod B. Pod B doesn't need any permissions — it only produces logs.

---

## Prerequisites

- A running Kubernetes cluster (minikube, kind, EKS, GKE, AKS, etc.)
- `kubectl` configured with permission to create namespaces, roles and role bindings

---

## File Structure

```
.
├── 00-namespace.yaml
├── 01-serviceaccount.yaml
├── 02-role.yaml
├── 03-rolebinding.yaml
├── 04-pod-a.yaml
└── 05-pod-b.yaml
```

---

## Step 1: Create the Namespace

**`00-namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: sa-demo
```

```bash
kubectl apply -f 00-namespace.yaml
```

---

## Step 2: Create the ServiceAccount

**`01-serviceaccount.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reader-sa
  namespace: sa-demo
```

```bash
kubectl apply -f 01-serviceaccount.yaml
```

---

## Step 3: Create the Role

Reading logs requires access to the `pods/log` **subresource**. `get`/`list` on `pods` lets Pod A find and list pods in the namespace.

**`02-role.yaml`**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-log-reader
  namespace: sa-demo
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
```

```bash
kubectl apply -f 02-role.yaml
```

> To restrict Pod A to **only** Pod B's logs, add `resourceNames: ["pod-b"]` under the `pods/log` rule.

---

## Step 4: Create the RoleBinding

**`03-rolebinding.yaml`**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: log-reader-binding
  namespace: sa-demo
subjects:
  - kind: ServiceAccount
    name: log-reader-sa
    namespace: sa-demo
roleRef:
  kind: Role
  name: pod-log-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 03-rolebinding.yaml
```

---

## Step 5: Create Pod B (no ServiceAccount)

Pod B prints a log line every 5 seconds so there's something to read.

**`05-pod-b.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-b
  namespace: sa-demo
  labels:
    app: pod-b
spec:
  automountServiceAccountToken: false   # no SA token mounted
  containers:
    - name: logger
      image: busybox:1.36
      command: ["/bin/sh", "-c"]
      args:
        - |
          i=0
          while true; do
            echo "pod-b log line $i at $(date)"
            i=$((i+1))
            sleep 5
          done
```

```bash
kubectl apply -f 05-pod-b.yaml
```

---

## Step 6: Create Pod A (with the ServiceAccount)

Pod A uses the `bitnami/kubectl` image so `kubectl` and `curl` are available inside it. It just sleeps so we can exec into it.

**`04-pod-a.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-a
  namespace: sa-demo
  labels:
    app: pod-a
spec:
  serviceAccountName: log-reader-sa
  automountServiceAccountToken: true
  containers:
    - name: reader
      image: bitnami/kubectl:latest
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f 04-pod-a.yaml
```

---

## Step 7: Verify Everything Is Running

```bash
kubectl get sa,role,rolebinding,pods -n sa-demo
```

Confirm which ServiceAccount each pod uses:

```bash
kubectl get pod pod-a -n sa-demo -o jsonpath='{.spec.serviceAccountName}{"\n"}'
# log-reader-sa

kubectl get pod pod-b -n sa-demo -o jsonpath='{.spec.serviceAccountName}{"\n"}'
# default  (but no token is mounted)
```

Check permissions from outside before testing:

```bash
kubectl auth can-i get pods/log \
  --as=system:serviceaccount:sa-demo:log-reader-sa -n sa-demo
# yes

kubectl auth can-i delete pods \
  --as=system:serviceaccount:sa-demo:log-reader-sa -n sa-demo
# no
```

---

## Step 8: Read Pod B's Logs from Inside Pod A

Exec into Pod A:

```bash
kubectl exec -it pod-a -n sa-demo -- bash
```

### Option A — using `kubectl` inside the pod

`kubectl` automatically uses the mounted SA token at `/var/run/secrets/kubernetes.io/serviceaccount/`.

```bash
kubectl get pods -n sa-demo
kubectl logs pod-b -n sa-demo
kubectl logs pod-b -n sa-demo --tail=5
kubectl logs pod-b -n sa-demo -f        # stream (Ctrl+C to stop)
```

### Option B — calling the API directly with `curl`

```bash
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat $SA_DIR/token)
NAMESPACE=$(cat $SA_DIR/namespace)
CACERT=$SA_DIR/ca.crt
APISERVER=https://kubernetes.default.svc

curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NAMESPACE/pods/pod-b/log?tailLines=10"
```

### Confirm the permissions are limited

```bash
kubectl delete pod pod-b -n sa-demo
# Error from server (Forbidden): ... cannot delete resource "pods" ...

kubectl get secrets -n sa-demo
# Error from server (Forbidden): ... cannot list resource "secrets" ...
```

Exit the pod:

```bash
exit
```

---

## Step 9 (Optional): Confirm Pod B Has No Token

```bash
kubectl exec -it pod-b -n sa-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount
# ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

---

## Apply Everything at Once

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-serviceaccount.yaml -f 02-role.yaml -f 03-rolebinding.yaml
kubectl apply -f 05-pod-b.yaml -f 04-pod-a.yaml
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b -n sa-demo --timeout=120s
kubectl exec -it pod-a -n sa-demo -- kubectl logs pod-b -n sa-demo --tail=5
```

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Forbidden: cannot get resource "pods/log"` | Role is missing the `pods/log` rule, or the RoleBinding subject name/namespace is wrong. |
| `Forbidden: cannot list resource "pods"` | Add `list` on `pods` in the Role. |
| `Unable to connect to the server` inside Pod A | Check `automountServiceAccountToken` isn't `false` on Pod A, and that cluster DNS works (`kubernetes.default.svc`). |
| Pod A in `ImagePullBackOff` | Use another image with kubectl, e.g. `alpine/k8s:1.30.0`, or check registry access. |
| Logs empty | Pod B may not be Running yet — check `kubectl get pod pod-b -n sa-demo`. |

---

## Cleanup

```bash
kubectl delete namespace sa-demo
```

This removes the ServiceAccount, Role, RoleBinding and both pods.
