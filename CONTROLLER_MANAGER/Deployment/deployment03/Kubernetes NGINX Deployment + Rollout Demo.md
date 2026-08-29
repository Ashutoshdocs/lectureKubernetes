# 24. Check Revision History

Kubernetes maintains a revision history for the Deployment.

Run:

```bash
kubectl rollout history deployment nginx-demo
```

Example:

```text
deployment.apps/nginx-demo

REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
3         Updated application to version v3
```

---

# 25. Add a Change Cause

There are two easy ways to add a change cause.

## Method 1 — Using `kubectl annotate`

After making a change to `deployment.yaml`, apply it:

```bash
kubectl apply -f deployment.yaml
```

Then add a change-cause annotation:

```bash
kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Updated application to version v2" \
  --overwrite
```

Check:

```bash
kubectl rollout history deployment nginx-demo
```

You should see:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
```

---

# 26. Recommended Method — Add Change Cause Before Applying

You can also put the annotation directly inside `deployment.yaml`.

Add:

```yaml
metadata:
  name: nginx-demo
  annotations:
    kubernetes.io/change-cause: "Initial deployment"
```

For example:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nginx-demo

  annotations:
    kubernetes.io/change-cause: "Initial deployment"

spec:
  replicas: 3

  revisionHistoryLimit: 10

  selector:
    matchLabels:
      app: nginx-demo

  template:
    metadata:
      labels:
        app: nginx-demo

    spec:
      # containers...
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Then:

```bash
kubectl rollout history deployment nginx-demo
```

---

# 27. Version 2 with Change Cause

Edit:

```bash
vim deployment.yaml
```

Change:

```yaml
annotations:
  kubernetes.io/change-cause: "Initial deployment"
```

to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v2"
```

Also change:

```yaml
- name: APP_VERSION
  value: "v1"
```

to:

```yaml
- name: APP_VERSION
  value: "v2"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Check rollout:

```bash
kubectl rollout status deployment nginx-demo
```

Check history:

```bash
kubectl rollout history deployment nginx-demo
```

Expected:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
```

---

# 28. Version 3 with Change Cause

Change:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v2"
```

to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v3"
```

And change:

```yaml
- name: APP_VERSION
  value: "v2"
```

to:

```yaml
- name: APP_VERSION
  value: "v3"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

Then:

```bash
kubectl rollout history deployment nginx-demo
```

Expected:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
3         Updated application to version v3
```

---

# 29. View Details of a Revision

View revision 1:

```bash
kubectl rollout history deployment nginx-demo --revision=1
```

View revision 2:

```bash
kubectl rollout history deployment nginx-demo --revision=2
```

View revision 3:

```bash
kubectl rollout history deployment nginx-demo --revision=3
```

---

# 30. Rollback to a Specific Revision

For example, rollback to revision 2:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

Then:

```bash
kubectl rollout history deployment nginx-demo
```

---

# 31. Important Note About Change Cause

The annotation:

```yaml
kubernetes.io/change-cause: "Updated application to version v2"
```

is used by:

```bash
kubectl rollout history
```

to populate the:

```text
CHANGE-CAUSE
```

column.

The change cause is **just a description**. It does not itself trigger a rollout.

A new Deployment revision is created when the **Pod template changes**.

For example, changing:

```yaml
- name: APP_VERSION
  value: "v1"
```

to:

```yaml
- name: APP_VERSION
  value: "v2"
```

changes the Pod template and creates a new revision.

---

# 32. Recommended Versioning Workflow

Use this workflow for every release:

### Version 1

```yaml
annotations:
  kubernetes.io/change-cause: "Initial deployment"
```

```yaml
- name: APP_VERSION
  value: "v1"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

### Version 2

```yaml
annotations:
  kubernetes.io/change-cause: "Updated NGINX dashboard to v2"
```

```yaml
- name: APP_VERSION
  value: "v2"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

### Version 3

```yaml
annotations:
  kubernetes.io/change-cause: "Updated dashboard and configuration to v3"
```

```yaml
- name: APP_VERSION
  value: "v3"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Then:

```bash
kubectl rollout history deployment nginx-demo
```

Expected:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated NGINX dashboard to v2
3         Updated dashboard and configuration to v3
```

---

# 33. Quick Method Using kubectl

If you don't want to edit the YAML annotation every time, you can set the change cause from the command line.

### Version 2

```bash
kubectl apply -f deployment.yaml

kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Updated NGINX dashboard to v2" \
  --overwrite
```

### Version 3

```bash
kubectl apply -f deployment.yaml

kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Updated NGINX dashboard to v3" \
  --overwrite
```

Then:

```bash
kubectl rollout history deployment nginx-demo
```

---

# 34. Complete Rollout Demo

```bash
# Initial deployment
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# Add initial change cause
kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Initial deployment" \
  --overwrite

# Check history
kubectl rollout history deployment nginx-demo


# Change v1 -> v2
vim deployment.yaml

kubectl apply -f deployment.yaml

kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Updated application to version v2" \
  --overwrite

kubectl rollout status deployment nginx-demo


# Change v2 -> v3
vim deployment.yaml

kubectl apply -f deployment.yaml

kubectl annotate deployment nginx-demo \
  kubernetes.io/change-cause="Updated application to version v3" \
  --overwrite

kubectl rollout status deployment nginx-demo


# View history
kubectl rollout history deployment nginx-demo


# View revision 1
kubectl rollout history deployment nginx-demo --revision=1


# View revision 2
kubectl rollout history deployment nginx-demo --revision=2


# View revision 3
kubectl rollout history deployment nginx-demo --revision=3


# Rollback to revision 2
kubectl rollout undo deployment nginx-demo --to-revision=2


# Verify
kubectl rollout status deployment nginx-demo

kubectl rollout history deployment nginx-demo
```

## Final Expected History

```text
deployment.apps/nginx-demo

REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated NGINX dashboard to v2
3         Updated NGINX dashboard to v3
4         Updated NGINX dashboard to v2
```

The last revision can be **revision 4** because a rollback itself creates a new Deployment revision. This is an important point to demonstrate: **rollback does not delete the newer revision; Kubernetes creates a new revision using the old Pod template.**
