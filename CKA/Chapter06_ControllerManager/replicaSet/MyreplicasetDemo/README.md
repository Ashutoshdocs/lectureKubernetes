# Kubernetes ReplicaSet Demo — Update YAML from RSv1 to RSv2

## 🎯 Demo Objective

This practical demonstrates an important ReplicaSet concept:

> **Update the image in the YAML file, apply the YAML, and observe that existing Pods continue running the old image until they are recreated.**

We will use:

- **One ReplicaSet YAML**
- **One Service YAML**
- **Two Docker images**
  - `rsv1`
  - `rsv2`
- One NodePort Service to access the application
- YAML-based scaling
- Image update from **RSv1 → RSv2**

---

# 📁 Project Structure

```text
MyreplicasetDemo/
│
├── Dockerfile-rsv1
├── Dockerfile-rsv2
│
├── index-rsv1.html
├── index-rsv2.html
│
├── replicaset.yaml
├── service.yaml
│
└── README.md
```

---

# 1. Prerequisites

Verify Docker:

```bash
docker --version
```

Verify Kubernetes:

```bash
kubectl version --client
```

Verify cluster:

```bash
kubectl get nodes
```

Login to Docker Hub:

```bash
docker login
```

---

# 2. Build RSv1 Image

Build the first application image:

```bash
docker build -f Dockerfile-rsv1 -t DOCKERHUB_USERNAME/myreplicasetdemo:rsv1 .
```

Verify:

```bash
docker images | grep myreplicasetdemo
```

Optional local test:

```bash
docker run -d --name rsv1-test -p 8081:80 DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

Open:

```text
http://localhost:8081
```

You should see:

```text
RSv1
```

Remove the test container:

```bash
docker rm -f rsv1-test
```

---

# 3. Push RSv1 to Docker Hub

```bash
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

---

# 4. Build RSv2 Image

Build the second version:

```bash
docker build -f Dockerfile-rsv2 -t DOCKERHUB_USERNAME/myreplicasetdemo:rsv2 .
```

Optional local test:

```bash
docker run -d --name rsv2-test -p 8082:80 DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Open:

```text
http://localhost:8082
```

You should see:

```text
RSv2
```

Remove the test container:

```bash
docker rm -f rsv2-test
```

---

# 5. Push RSv2 to Docker Hub

```bash
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Docker Hub now contains:

```text
DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Replace `DOCKERHUB_USERNAME` with your actual Docker Hub username in `replicaset.yaml`.

---

# 6. Create the ReplicaSet YAML

The single `replicaset.yaml` initially points to **RSv1**:

```yaml
apiVersion: apps/v1
kind: ReplicaSet

metadata:
  name: nginx-rs

spec:
  replicas: 3

  selector:
    matchLabels:
      app: nginx-rs

  template:
    metadata:
      labels:
        app: nginx-rs

    spec:
      containers:
        - name: nginx
          image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
          ports:
            - containerPort: 80
```

---

# 7. Create the ReplicaSet

Apply the YAML:

```bash
kubectl apply -f replicaset.yaml
```

Verify:

```bash
kubectl get rs
```

Expected:

```text
NAME       DESIRED   CURRENT   READY
nginx-rs   3         3         3
```

---

# 8. Check the Pods

```bash
kubectl get pods -o wide
```

You should have 3 Pods.

Verify the image:

```bash
kubectl describe pod <pod-name> | grep Image
```

Expected:

```text
myreplicasetdemo:rsv1
```

---

# 9. Create the NodePort Service

Use a single Service:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: nginx-rs-service

spec:
  type: NodePort

  selector:
    app: nginx-rs

  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 30081
```

Apply:

```bash
kubectl apply -f service.yaml
```

Verify:

```bash
kubectl get svc
```

---

# 10. Access RSv1 from Browser

Find the node IP:

```bash
kubectl get nodes -o wide
```

Open:

```text
http://<NODE-IP>:30081
```

You should see the beautiful:

```text
RSv1
```

---

# 11. Demonstrate Scale Up

Increase the ReplicaSet:

```bash
kubectl scale rs nginx-rs --replicas=5
```

Verify:

```bash
kubectl get rs
kubectl get pods
```

Expected:

```text
DESIRED   CURRENT   READY
5         5         5
```

The ReplicaSet creates additional Pods.

---

# 12. Demonstrate Scale Down

Reduce the ReplicaSet:

```bash
kubectl scale rs nginx-rs --replicas=2
```

Verify:

```bash
kubectl get rs
kubectl get pods
```

Expected:

```text
DESIRED   CURRENT   READY
2         2         2
```

---

# 13. ⭐ Main Demo — Update YAML from RSv1 to RSv2

This is the most important part of the practical.

Currently `replicaset.yaml` contains:

```yaml
image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

Edit the YAML:

```bash
vi replicaset.yaml
```

Change:

```yaml
image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

to:

```yaml
image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Save the file.

---

# 14. Apply the Updated YAML

Run:

```bash
kubectl apply -f replicaset.yaml
```

The ReplicaSet template is now updated to:

```text
RSv2
```

Check:

```bash
kubectl get rs
```

---

# 15. Check Existing Pods

Run:

```bash
kubectl get pods
```

Then:

```bash
kubectl describe pod <pod-name> | grep Image
```

You may still see:

```text
myreplicasetdemo:rsv1
```

This is the key ReplicaSet behavior.

## Why?

A ReplicaSet uses its Pod template when it **creates new Pods**.

It does not automatically replace existing Pods when the template changes.

```text
ReplicaSet Template
        │
        │ changed
        ▼
     RSv2 image
        │
        X
Existing Pods are NOT automatically rebuilt
```

---

# 16. Force the ReplicaSet to Create RSv2 Pods

Delete the existing Pods:

```bash
kubectl delete pod -l app=nginx-rs
```

Do NOT delete the ReplicaSet.

The ReplicaSet immediately notices:

```text
Desired Pods = 2
Current Pods = 0
```

It therefore creates new Pods.

---

# 17. Verify the New Pods

```bash
kubectl get pods -o wide
```

Verify the image:

```bash
kubectl describe pod <pod-name> | grep Image
```

Now you should see:

```text
myreplicasetdemo:rsv2
```

---

# 18. Refresh the Browser

Open:

```text
http://<NODE-IP>:30081
```

Refresh the page.

You should now see:

```text
RSv2
```

The same Service continues to work because it selects:

```yaml
selector:
  app: nginx-rs
```

It does not care whether the Pods are running RSv1 or RSv2.

---

# 19. Complete Demo Flow

```text
Dockerfile-rsv1
      │
      ▼
Build RSv1 Image
      │
      ▼
Docker Hub
      │
      ▼
ReplicaSet YAML
image: rsv1
      │
      ▼
kubectl apply
      │
      ▼
3 Pods running RSv1
      │
      ▼
NodePort Service
      │
      ▼
Browser → RSv1
```

Then:

```text
Edit replicaset.yaml

rsv1
  │
  ▼
rsv2
  │
  ▼
kubectl apply
  │
  ▼
ReplicaSet template = RSv2
  │
  │
  └── Existing Pods remain RSv1
          │
          ▼
kubectl delete pod -l app=nginx-rs
          │
          ▼
ReplicaSet creates new Pods
          │
          ▼
New Pods = RSv2
          │
          ▼
Browser → RSv2
```

---

# 20. Important Difference: `kubectl edit` vs YAML

### `kubectl edit`

```bash
kubectl edit rs nginx-rs
```

Changes the **live ReplicaSet object**.

It does not update your local YAML file.

### YAML + apply

```bash
vi replicaset.yaml
kubectl apply -f replicaset.yaml
```

Changes your configuration file and then updates the live object.

This is the recommended approach for maintaining a reproducible configuration.

---

# 21. Scale Using YAML

If the current YAML contains:

```yaml
replicas: 2
```

Change it to:

```yaml
replicas: 5
```

Then:

```bash
kubectl apply -f replicaset.yaml
```

The desired ReplicaSet count becomes 5.

This demonstrates the difference between:

```text
kubectl scale
```

and:

```text
YAML + kubectl apply
```

---

# 22. Important ReplicaSet Mental Model

```text
                 ReplicaSet
                     │
                     │
             Pod Template
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
        Pod 1      Pod 2      Pod 3
        RSv2       RSv2       RSv2
```

The ReplicaSet continuously maintains the desired number of Pods.

If a Pod is deleted:

```text
Pod 1 ❌
Pod 2 ✅
Pod 3 ✅
        │
        ▼
ReplicaSet reconciliation
        │
        ▼
New Pod created
        │
        ▼
New Pod uses current template
```

---

# 23. ReplicaSet vs Deployment

| Feature | ReplicaSet | Deployment |
|---|---|---|
| Maintains desired replicas | ✅ | ✅ |
| Recreates deleted Pods | ✅ | ✅ |
| Image rolling update | ❌ | ✅ |
| Automatic replacement of existing Pods after image change | ❌ | ✅ |
| Rollout history | ❌ | ✅ |
| Rollback | ❌ | ✅ |

For this lab, ReplicaSet is used intentionally to demonstrate the underlying controller behavior.

---

# 24. Quick Command Reference

```bash
# Build images
docker build -f Dockerfile-rsv1 -t DOCKERHUB_USERNAME/myreplicasetdemo:rsv1 .
docker build -f Dockerfile-rsv2 -t DOCKERHUB_USERNAME/myreplicasetdemo:rsv2 .

# Push images
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv2

# Create/update ReplicaSet
kubectl apply -f replicaset.yaml

# Inspect
kubectl get rs
kubectl get pods -o wide
kubectl describe pod <pod-name> | grep Image

# Scale
kubectl scale rs nginx-rs --replicas=5
kubectl scale rs nginx-rs --replicas=2

# Update YAML
vi replicaset.yaml
kubectl apply -f replicaset.yaml

# Recreate Pods using the new template
kubectl delete pod -l app=nginx-rs

# Service
kubectl apply -f service.yaml
kubectl get svc
```

---

# ⭐ Golden Rule

> **Changing the ReplicaSet YAML changes the ReplicaSet's Pod template. Existing Pods are not automatically replaced.**

Therefore:

```text
Update YAML
     ↓
kubectl apply
     ↓
ReplicaSet template = RSv2
     ↓
Delete old Pods
     ↓
ReplicaSet creates new Pods
     ↓
New Pods use RSv2
```

This is the core behavior this practical is designed to demonstrate.
