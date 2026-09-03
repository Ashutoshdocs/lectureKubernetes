# Docker Container vs Kubernetes Pod — Practical Demo

## 📌 Objective

This practical demonstrates the difference between:

- Docker Container
- Kubernetes Pod
- Kubernetes Deployment
- ReplicaSet
- Multi-container Pod

We will run the **same Nginx application** using Docker and Kubernetes and compare their lifecycle, networking, scaling, and self-healing behavior.

---

# 1. Architecture

## Docker

```text
Docker Engine
     │
     ▼
 Container
     │
     ▼
  Nginx
```

## Kubernetes

```text
Kubernetes
     │
     ▼
 Deployment
     │
     ▼
 ReplicaSet
     │
     ▼
   Pod
     │
     ▼
 Container
     │
     ▼
  Nginx
```

---

# 2. Prerequisites

Install/configure:

```bash
docker --version
```

```bash
kubectl version --client
```

Verify Kubernetes:

```bash
kubectl get nodes
```

Expected:

```text
NAME       STATUS   ROLES           AGE
master     Ready    control-plane   ...
worker     Ready    <none>          ...
```

---

# 3. Part 1 — Run Nginx Using Docker

## Step 1 — Pull Nginx image

```bash
docker pull nginx:alpine
```

Verify:

```bash
docker images
```

---

## Step 2 — Create Docker container

```bash
docker run -d \
  --name docker-nginx \
  -p 8080:80 \
  nginx:alpine
```

Explanation:

```text
-d
```

Runs the container in detached mode.

```text
--name docker-nginx
```

Assigns a name to the container.

```text
-p 8080:80
```

Maps:

```text
Host Port 8080
      │
      ▼
Container Port 80
```

---

## Step 3 — Check container

```bash
docker ps
```

Expected:

```text
CONTAINER ID   IMAGE          PORTS
xxxxxx         nginx:alpine  0.0.0.0:8080->80/tcp
```

---

## Step 4 — Test Nginx

```bash
curl http://localhost:8080
```

You should receive the Nginx HTML response.

If running on an Azure VM:

```text
http://<VM-IP>:8080
```

Make sure the required Azure NSG rule allows TCP port `8080`.

---

# 4. Explore the Docker Container

## View logs

```bash
docker logs docker-nginx
```

---

## Execute a command inside container

```bash
docker exec -it docker-nginx /bin/sh
```

Inside the container:

```bash
hostname
```

Check processes:

```bash
ps
```

Exit:

```bash
exit
```

---

## Inspect container

```bash
docker inspect docker-nginx
```

This displays information such as:

- Container ID
- Image
- Network
- IP address
- Mounts
- Environment
- Ports
- Runtime configuration

---

# 5. Docker Container Lifecycle

Stop the container:

```bash
docker stop docker-nginx
```

Check:

```bash
docker ps
```

The container is no longer running.

Check all containers:

```bash
docker ps -a
```

Start it again:

```bash
docker start docker-nginx
```

Remove it:

```bash
docker rm -f docker-nginx
```

Verify:

```bash
docker ps -a
```

---

# 6. Part 2 — Create a Kubernetes Pod

Create the file:

```bash
nano nginx-pod.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: nginx-pod

spec:
  containers:
    - name: nginx
      image: nginx:alpine

      ports:
        - containerPort: 80
```

---

# 7. Create the Pod

```bash
kubectl apply -f nginx-pod.yaml
```

Check:

```bash
kubectl get pods
```

Expected:

```text
NAME         READY   STATUS    RESTARTS   AGE
nginx-pod    1/1     Running   0          10s
```

---

# 8. Get Detailed Pod Information

```bash
kubectl describe pod nginx-pod
```

View complete YAML:

```bash
kubectl get pod nginx-pod -o yaml
```

View Pod IP:

```bash
kubectl get pod nginx-pod -o wide
```

Example:

```text
NAME         READY   STATUS    IP            NODE
nginx-pod    1/1     Running   10.244.1.10   worker
```

---

# 9. Access the Kubernetes Pod

A Pod does not automatically expose port `80` outside the cluster.

For testing, use:

```bash
kubectl port-forward pod/nginx-pod 8080:80
```

Expected:

```text
Forwarding from 127.0.0.1:8080 -> 80
```

In another terminal:

```bash
curl http://localhost:8080
```

---

# 10. Compare Port Mapping

### Docker

```bash
docker run -d \
  --name docker-nginx \
  -p 8080:80 \
  nginx:alpine
```

Docker directly maps:

```text
Host
8080
 │
 ▼
Container
80
```

### Kubernetes

For testing:

```bash
kubectl port-forward pod/nginx-pod 8080:80
```

Production Kubernetes applications normally use a:

```text
Service
```

instead of relying on `kubectl port-forward`.

---

# 11. Execute Commands Inside Kubernetes Container

Run:

```bash
kubectl exec -it nginx-pod -- /bin/sh
```

Inside:

```bash
hostname
```

Check Nginx:

```bash
ps
```

Exit:

```bash
exit
```

---

# 12. Kubernetes Pod Lifecycle

Check the Pod:

```bash
kubectl get pod nginx-pod
```

Delete it:

```bash
kubectl delete pod nginx-pod
```

Check again:

```bash
kubectl get pods
```

Expected:

```text
No resources found
```

## Important

A standalone Pod is **not automatically recreated** when you delete it.

This is because no controller is managing the desired number of Pods.

---

# 13. Part 3 — Create a Deployment

Create:

```bash
nano nginx-deployment.yaml
```

Add:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nginx-demo

spec:
  replicas: 1

  selector:
    matchLabels:
      app: nginx

  template:

    metadata:
      labels:
        app: nginx

    spec:

      containers:
        - name: nginx
          image: nginx:alpine

          ports:
            - containerPort: 80
```

---

# 14. Create the Deployment

```bash
kubectl apply -f nginx-deployment.yaml
```

Check Deployment:

```bash
kubectl get deployments
```

Check ReplicaSet:

```bash
kubectl get replicasets
```

Check Pods:

```bash
kubectl get pods
```

Architecture:

```text
Deployment
     │
     ▼
 ReplicaSet
     │
     ▼
   Pod
     │
     ▼
Container
     │
     ▼
 Nginx
```

---

# 15. Demonstrate Kubernetes Self-Healing

Get the Pod:

```bash
kubectl get pods
```

Example:

```text
NAME                          READY   STATUS
nginx-demo-7d9f8c6d7f-x7abc   1/1     Running
```

Delete the Pod:

```bash
kubectl delete pod nginx-demo-7d9f8c6d7f-x7abc
```

Immediately check:

```bash
kubectl get pods
```

A new Pod should be created.

Example:

```text
NAME                          READY   STATUS
nginx-demo-7d9f8c6d7f-q9xyz   1/1     Running
```

---

# 16. Why Was the Pod Recreated?

The Deployment manages a ReplicaSet.

The ReplicaSet has a desired state:

```text
Desired Pods = 1
```

If the current state becomes:

```text
Current Pods = 0
```

The ReplicaSet creates a new Pod.

```text
Desired State
     │
     ▼
ReplicaSet
     │
     │ detects
     ▼
Current State
     │
     └── 0 Pods
           │
           ▼
      Create new Pod
```

---

# 17. Part 4 — Demonstrate Scaling

Check current replicas:

```bash
kubectl get deployment nginx-demo
```

Scale to 5 Pods:

```bash
kubectl scale deployment nginx-demo --replicas=5
```

Check:

```bash
kubectl get pods
```

Expected:

```text
NAME                          READY   STATUS
nginx-demo-xxx-aaa            1/1     Running
nginx-demo-xxx-bbb            1/1     Running
nginx-demo-xxx-ccc            1/1     Running
nginx-demo-xxx-ddd            1/1     Running
nginx-demo-xxx-eee            1/1     Running
```

Check:

```bash
kubectl get deployment
```

Expected:

```text
NAME         READY   UP-TO-DATE   AVAILABLE
nginx-demo   5/5     5            5
```

---

# 18. Docker vs Kubernetes Scaling

## Docker

Multiple containers can be started manually:

```bash
docker run -d nginx
docker run -d nginx
docker run -d nginx
docker run -d nginx
docker run -d nginx
```

Docker itself does not provide Kubernetes-style Deployment/ReplicaSet desired-state management.

## Kubernetes

```bash
kubectl scale deployment nginx-demo --replicas=5
```

Kubernetes maintains:

```text
Desired = 5 Pods
```

---

# 19. Part 5 — Multi-Container Pod

One of the most important differences is that a Pod can contain multiple containers.

Create:

```bash
nano multi-container-pod.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: multi-container-demo

spec:

  containers:

    - name: nginx
      image: nginx:alpine

    - name: sidecar
      image: busybox:1.36

      command:
        - sh
        - -c
        - |
          while true; do
            echo "Sidecar running"
            sleep 10
          done
```

Create:

```bash
kubectl apply -f multi-container-pod.yaml
```

Check:

```bash
kubectl get pods
```

Expected:

```text
NAME                   READY
multi-container-demo   2/2
```

---

# 20. Verify Both Containers

List containers:

```bash
kubectl get pod multi-container-demo \
  -o jsonpath='{.spec.containers[*].name}'
```

Expected:

```text
nginx sidecar
```

View Nginx logs:

```bash
kubectl logs multi-container-demo -c nginx
```

View sidecar logs:

```bash
kubectl logs multi-container-demo -c sidecar
```

---

# 21. Demonstrate Shared Networking

Enter the sidecar:

```bash
kubectl exec -it multi-container-demo \
  -c sidecar -- sh
```

Inside:

```bash
wget -qO- http://localhost:80
```

The sidecar can access Nginx through:

```text
localhost:80
```

Why?

Because containers inside the same Pod share the Pod's network namespace.

Architecture:

```text
                 Pod
                  │
          Pod IP / Network
                  │
        ┌─────────┴─────────┐
        │                   │
      nginx               sidecar
        │                   │
        └────── localhost ──┘
```

---

# 22. Important Pod Concepts

Containers in the same Pod share:

### Network

They share:

```text
Pod IP
```

and can communicate using:

```text
localhost
```

### Volumes

Containers can share volumes mounted into the Pod.

Example:

```text
Pod
│
├── nginx
│
├── sidecar
│
└── shared volume
```

### Lifecycle

The Pod is the Kubernetes scheduling and management unit.

---

# 23. Docker Container vs Kubernetes Pod

| Feature | Docker Container | Kubernetes Pod |
|---|---|---|
| Basic purpose | Application runtime | Kubernetes execution unit |
| Managed by | Docker/container runtime | Kubernetes |
| Contains | Usually one application process/container | One or more containers |
| Networking | Container network | Shared Pod network |
| IP | Container gets networking | Pod has the IP |
| Scaling | Manual/container tooling | Deployment/ReplicaSet/HPA etc. |
| Self-healing | Not by itself | Controllers can recreate Pods |
| Scheduling | Docker host decides | Kubernetes scheduler |
| Configuration | CLI / Docker configuration | YAML / API objects |
| Logs | `docker logs` | `kubectl logs` |
| Execute | `docker exec` | `kubectl exec` |
| Inspect | `docker inspect` | `kubectl describe` / YAML |
| Lifecycle | Container lifecycle | Pod lifecycle + container lifecycle |

---

# 24. Most Important Concept

Do **not** teach this as:

```text
Docker Container = Kubernetes Pod
```

Instead:

```text
Container
   │
   │ runs application
   ▼
Application Process
```

Kubernetes adds an abstraction around containers:

```text
Kubernetes
    │
    ▼
   Pod
    │
    ▼
Container
    │
    ▼
Application
```

A Pod can also contain multiple containers:

```text
        Pod
         │
    ┌────┴────┐
    ▼         ▼
Container  Container
   App       Sidecar
```

---

# 25. Interview Question

### Q: Is a Kubernetes Pod the same as a Docker container?

### Answer:

No.

A Docker container is a runtime instance of a container image.

A Kubernetes Pod is the smallest deployable unit in Kubernetes and provides the execution environment for one or more containers.

---

# 26. Interview Question

### Q: Why does Kubernetes use Pods instead of directly managing containers?

### Answer:

The Pod provides a higher-level abstraction for:

- Networking
- Storage sharing
- Container grouping
- Lifecycle management
- Scheduling
- Sidecar patterns

Containers that belong together can be placed inside the same Pod.

---

# 27. Interview Question

### Q: What happens if you delete a Pod created by a Deployment?

The Deployment's ReplicaSet notices that the desired number of Pods is no longer available and creates a replacement Pod.

```text
Deployment
     │
     ▼
ReplicaSet
     │
     ▼
Pod
     │
     X
  Deleted
     │
     ▼
ReplicaSet
     │
     ▼
New Pod
```

---

# 28. Interview Question

### Q: Can a Pod have multiple containers?

Yes.

Example:

```text
Pod
│
├── Application Container
│
└── Sidecar Container
```

Common examples include:

- Logging sidecar
- Proxy sidecar
- Monitoring sidecar
- Configuration/reloader sidecar

---

# 29. Cleanup

Delete the Deployment:

```bash
kubectl delete deployment nginx-demo
```

Delete the multi-container Pod:

```bash
kubectl delete pod multi-container-demo
```

Verify:

```bash
kubectl get pods
```

Delete the YAML files if no longer required:

```bash
rm -f nginx-pod.yaml
rm -f nginx-deployment.yaml
rm -f multi-container-pod.yaml
```

---

# 30. Final Teaching Summary

Use this final diagram on the board:

```text
                  DOCKER
                  ======

              Docker Engine
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
      Container Container Container
          │        │        │
         App      App      App
```

Kubernetes:

```text
                KUBERNETES
                ==========

               Deployment
                   │
               ReplicaSet
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
         Pod      Pod      Pod
          │        │        │
       Container Container Container
          │        │        │
         App      App      App
```

Multi-container Pod:

```text
                 Pod
                  │
          ┌───────┴───────┐
          ▼               ▼
    App Container    Sidecar Container
          │               │
          └───────┬───────┘
                  │
           Shared Network
                  │
              Same Pod IP
```

## Golden Rule

```text
Docker:
Container is the primary runtime unit.

Kubernetes:
Pod is the smallest deployable unit,
and containers run inside the Pod.
```

---

## Quick Command Reference

### Docker

```bash
docker pull nginx:alpine

docker run -d \
  --name docker-nginx \
  -p 8080:80 \
  nginx:alpine

docker ps

docker logs docker-nginx

docker exec -it docker-nginx /bin/sh

docker inspect docker-nginx

docker stop docker-nginx

docker start docker-nginx

docker rm -f docker-nginx
```

### Kubernetes

```bash
kubectl apply -f nginx-pod.yaml

kubectl get pods

kubectl get pods -o wide

kubectl describe pod nginx-pod

kubectl logs nginx-pod

kubectl exec -it nginx-pod -- /bin/sh

kubectl port-forward pod/nginx-pod 8080:80

kubectl delete pod nginx-pod

kubectl apply -f nginx-deployment.yaml

kubectl get deployment

kubectl get replicasets

kubectl scale deployment nginx-demo --replicas=5

kubectl delete deployment nginx-demo
```

---

# 🎯 Practical Outcome

After completing this lab, students should be able to explain:

```text
Image
  ↓
Container
  ↓
Pod
  ↓
ReplicaSet
  ↓
Deployment
```

and understand that **Kubernetes does not replace containers; it orchestrates containers through Kubernetes abstractions such as Pods and controllers.**