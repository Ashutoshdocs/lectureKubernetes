# Kubernetes ReplicaSet Demo — RSv1 → RSv2

A hands-on teaching lab demonstrating how a **ReplicaSet** manages Pods, how to scale up/down, how `kubectl edit` changes the live ReplicaSet template, and why existing Pods do not automatically change their image.

The lab uses two custom Docker images:

- `MyreplicasetDemo:rsv1` → beautiful RSv1 page
- `MyreplicasetDemo:rsv2` → beautiful RSv2 page

> Docker Hub image names are lowercase. Replace `DOCKERHUB_USERNAME` below with your Docker Hub username.

## Lab Structure

```text
MyreplicasetDemo/
├── Dockerfile-rsv1
├── Dockerfile-rsv2
├── index-rsv1.html
├── index-rsv2.html
├── replicaset-rsv1.yaml
├── replicaset-rsv2.yaml
├── service-rsv1.yaml
├── service-rsv2.yaml
└── README.md
```

## 1. Prerequisites

Verify:

```bash
docker --version
kubectl version --client
kubectl get nodes
```

Login to Docker Hub:

```bash
docker login
```

## 2. Build RSv1 Image

Build the image from `Dockerfile-rsv1`:

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

Clean up:

```bash
docker rm -f rsv1-test
```

## 3. Push RSv1 to Docker Hub

```bash
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

Verify the tag in Docker Hub.

## 4. Build RSv2 Image

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

Clean up:

```bash
docker rm -f rsv2-test
```

## 5. Push RSv2 to Docker Hub

```bash
docker push DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Now Docker Hub contains:

```text
DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

## 6. Update the Kubernetes YAML

Before applying the manifests, replace:

```text
DOCKERHUB_USERNAME
```

with your actual Docker Hub username.

For example:

```text
ashutosh/myreplicasetdemo:rsv1
ashutosh/myreplicasetdemo:rsv2
```

## 7. Deploy RSv1 ReplicaSet

Apply:

```bash
kubectl apply -f replicaset-rsv1.yaml
```

Verify:

```bash
kubectl get rs
kubectl get pods -o wide
```

Expected:

```text
nginx-rs   3   3   3
```

Check the image:

```bash
kubectl describe pod <pod-name> | grep Image
```

You should see:

```text
myreplicasetdemo:rsv1
```

## 8. Expose RSv1 with NodePort

Apply:

```bash
kubectl apply -f service-rsv1.yaml
```

Verify:

```bash
kubectl get svc
```

RSv1 uses:

```text
NodePort: 30081
```

Find a node IP:

```bash
kubectl get nodes -o wide
```

Access:

```text
http://<NODE-IP>:30081
```

You should see the **RSv1** page.

## 9. Demonstrate Scale Up

Increase the live ReplicaSet from 3 to 5:

```bash
kubectl scale rs nginx-rs --replicas=5
```

Verify:

```bash
kubectl get rs
kubectl get pods -o wide
```

Expected:

```text
DESIRED   CURRENT   READY
5         5         5
```

Important:

`kubectl scale` changes the **live ReplicaSet**. It does not automatically change the local YAML file.

## 10. Demonstrate Scale Down

Reduce the live ReplicaSet:

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

## 11. Demonstrate RSv1 → RSv2

The key ReplicaSet teaching point is:

> Changing the ReplicaSet Pod template does not recreate existing Pods.

Edit the live ReplicaSet:

```bash
kubectl edit rs nginx-rs
```

Change:

```yaml
image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv1
```

to:

```yaml
image: DOCKERHUB_USERNAME/myreplicasetdemo:rsv2
```

Save and exit.

Check:

```bash
kubectl get rs
kubectl get pods
```

Existing Pods may still be serving **RSv1**.

This is expected.

## 12. Force New Pods from the Updated Template

Delete the Pods managed by the ReplicaSet:

```bash
kubectl delete pod -l app=nginx-rs
```

The ReplicaSet detects that the current number of Pods is below the desired number and creates replacement Pods.

Check:

```bash
kubectl get pods -o wide
```

Verify the image:

```bash
kubectl describe pod <new-pod-name> | grep Image
```

The new Pods should use:

```text
myreplicasetdemo:rsv2
```

## 13. Observe RSv2 Through NodePort

The existing `service-rsv1.yaml` selects:

```yaml
version: rsv1
```

The RSv2 manifest uses:

```yaml
version: rsv2
```

Apply the RSv2 service:

```bash
kubectl apply -f service-rsv2.yaml
```

Verify:

```bash
kubectl get svc
```

RSv2 uses:

```text
NodePort: 30082
```

Access:

```text
http://<NODE-IP>:30082
```

You should see the **RSv2** page.

## 14. Important Selector Concept

The Services intentionally use different version labels:

```text
RSv1 Pods
  app=nginx-rs
  version=rsv1
       ↑
service-rsv1.yaml
```

and:

```text
RSv2 Pods
  app=nginx-rs
  version=rsv2
       ↑
service-rsv2.yaml
```

This makes it easy to demonstrate both versions independently.

## 15. Increase/Decrease Using YAML

For a persistent configuration change, edit the YAML:

```yaml
replicas: 5
```

Then:

```bash
kubectl apply -f replicaset-rsv1.yaml
```

This is different from:

```bash
kubectl scale rs nginx-rs --replicas=5
```

### Imperative

```text
kubectl scale
      ↓
Live Kubernetes object
```

### Declarative

```text
YAML
 ↓
kubectl apply
 ↓
Live Kubernetes object
```

## 16. Key Teaching Point: ReplicaSet vs Deployment

```text
ReplicaSet
    │
    ├── Maintains desired Pod count
    │
    ├── Recreates deleted Pods
    │
    └── Does NOT perform rolling image updates

Deployment
    │
    ├── Manages ReplicaSets
    │
    ├── Performs rolling updates
    │
    └── Supports rollout history/rollback
```

A ReplicaSet uses its Pod template when creating **new Pods**. Existing Pods are not rebuilt simply because the template changed.

## 17. Useful Commands

```bash
kubectl get rs
kubectl describe rs nginx-rs

kubectl get pods -o wide
kubectl describe pod <pod-name>

kubectl scale rs nginx-rs --replicas=5
kubectl scale rs nginx-rs --replicas=2

kubectl edit rs nginx-rs

kubectl delete pod -l app=nginx-rs

kubectl get svc
kubectl get nodes -o wide
```

## 18. Cleanup

Delete the Services:

```bash
kubectl delete -f service-rsv1.yaml
kubectl delete -f service-rsv2.yaml
```

Delete the ReplicaSet:

```bash
kubectl delete rs nginx-rs
```

## Golden Rule

> **ReplicaSet controls the number of Pods. Its Pod template is used when Pods are created. Changing the template does not automatically replace existing Pods.**

For production application updates, a **Deployment** is normally preferred because it provides controlled rollout and rollback behavior.
