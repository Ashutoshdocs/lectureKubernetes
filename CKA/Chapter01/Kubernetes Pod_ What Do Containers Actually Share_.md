# Kubernetes Pod: What Do Containers Actually Share?

## Objective

This practical demonstrates exactly what containers inside the **same Kubernetes Pod** share.

We will create two containers in one Pod and verify:

| Resource | Shared between containers? |
|---|---|
| Network namespace | ✅ Yes |
| Pod IP address | ✅ Yes |
| `localhost` | ✅ Yes |
| Network ports | ✅ Yes |
| Volumes | ✅ Yes, when mounted by both |
| Process namespace | ❌ Normally no |
| Root filesystem | ❌ No |
| Environment variables | ❌ No |
| Container image/filesystem | ❌ No |
| CPU/Memory limits | ❌ Configured per container |

> **Important:** Containers in a Pod are not simply two processes in the same container. They are separate containers that share selected Linux namespaces and resources.

---

# Architecture

```text
                    Kubernetes Pod
             ┌──────────────────────────┐
             │                          │
             │       Pod IP             │
             │      10.x.x.x             │
             │                          │
             │  ┌──────────────┐        │
             │  │ Container 1  │        │
             │  │ nginx        │        │
             │  │ Port 8080    │        │
             │  └──────┬───────┘        │
             │         │                │
             │      localhost          │
             │         │                │
             │  ┌──────┴───────┐        │
             │  │ Container 2  │        │
             │  │ busybox      │        │
             │  └──────────────┘        │
             │                          │
             │       Shared Network     │
             │                          │
             │  ┌────────────────────┐  │
             │  │ Shared Volume      │  │
             │  │ /shared            │  │
             │  └────────────────────┘  │
             │                          │
             └──────────────────────────┘
```

---

# 1. Create the Demo Pod

Create:

```bash
nano pod-sharing-demo.yaml
```

Add:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: pod-sharing-demo

spec:
  containers:

    # Container 1
    - name: nginx
      image: nginx:alpine

      ports:
        - containerPort: 80

      env:
        - name: CONTAINER_NAME
          value: "NGINX"

      volumeMounts:
        - name: shared-data
          mountPath: /shared

    # Container 2
    - name: debug
      image: busybox:1.36

      command:
        - sh
        - -c
        - |
          echo "Debug container started"
          sleep 3600

      env:
        - name: CONTAINER_NAME
          value: "DEBUG"

      volumeMounts:
        - name: shared-data
          mountPath: /shared

  volumes:

    - name: shared-data
      emptyDir: {}
```

Create the Pod:

```bash
kubectl apply -f pod-sharing-demo.yaml
```

Check:

```bash
kubectl get pod pod-sharing-demo -o wide
```

Expected:

```text
NAME                READY   STATUS    IP
pod-sharing-demo    2/2     Running   10.244.x.x
```

---

# 2. PROOF #1 — Containers Share the Network Namespace

This is one of the most important Pod concepts.

Both containers use the **same Pod network namespace**.

Check the Pod IP:

```bash
kubectl get pod pod-sharing-demo -o wide
```

Now check the IP from the nginx container:

```bash
kubectl exec pod-sharing-demo -c nginx -- hostname -i
```

Then from the debug container:

```bash
kubectl exec pod-sharing-demo -c debug -- hostname -i
```

Both should show the same Pod IP.

Example:

```text
10.244.1.15
```

and:

```text
10.244.1.15
```

### Conclusion

```text
Container 1 ─────┐
                 ├── Same network namespace
Container 2 ─────┘
```

---

# 3. PROOF #2 — Both Containers Share localhost

Start nginx in Container 1.

Nginx is listening on:

```text
0.0.0.0:80
```

Now enter Container 2:

```bash
kubectl exec -it pod-sharing-demo -c debug -- sh
```

Inside the debug container:

```bash
wget -qO- http://localhost
```

You should receive the nginx HTML page.

Example:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

This is strong proof that:

```text
debug container
       |
       | localhost:80
       ↓
nginx container
```

works because both containers share the same network namespace.

---

# 4. PROOF #3 — Containers Share the Pod's Network Ports

From the debug container:

```bash
wget -qO- http://127.0.0.1:80
```

This reaches nginx.

Now imagine the second container also tries to listen on port 80.

It cannot independently bind to the same port.

Why?

Because both containers are using the same network namespace.

```text
Pod Network Namespace

localhost
   │
   ├── :80  → nginx
   │
   └── :80  → debug ❌
```

Two processes cannot normally listen on the same IP/port combination.

---

# 5. PROOF #4 — Containers Can Share Files Through a Volume

The Pod contains:

```yaml
volumes:
  - name: shared-data
    emptyDir: {}
```

Both containers mount it:

```yaml
volumeMounts:
  - name: shared-data
    mountPath: /shared
```

Therefore:

```text
             emptyDir
                │
        ┌───────┴───────┐
        ↓               ↓
     nginx             debug
    /shared            /shared
```

---

## Write From Container 1

Run:

```bash
kubectl exec pod-sharing-demo -c nginx -- sh -c \
'echo "Hello from nginx" > /shared/message.txt'
```

Verify:

```bash
kubectl exec pod-sharing-demo -c nginx -- cat /shared/message.txt
```

Output:

```text
Hello from nginx
```

Now read the same file from Container 2:

```bash
kubectl exec pod-sharing-demo -c debug -- cat /shared/message.txt
```

Output:

```text
Hello from nginx
```

### Conclusion

The containers can share data **through a shared volume**.

---

# 6. PROOF #5 — Root Filesystems Are NOT Shared

This is very important.

Create a file in nginx:

```bash
kubectl exec pod-sharing-demo -c nginx -- \
sh -c 'echo "nginx file" > /tmp/nginx.txt'
```

Check it:

```bash
kubectl exec pod-sharing-demo -c nginx -- cat /tmp/nginx.txt
```

Output:

```text
nginx file
```

Now try from debug:

```bash
kubectl exec pod-sharing-demo -c debug -- cat /tmp/nginx.txt
```

Expected:

```text
cat: can't open '/tmp/nginx.txt': No such file or directory
```

### Conclusion

The root filesystems are separate.

```text
Pod
│
├── nginx container
│   └── /tmp
│
└── debug container
    └── /tmp
```

They do NOT automatically see each other's files.

---

# 7. PROOF #6 — Environment Variables Are NOT Shared

Check the environment variable in nginx:

```bash
kubectl exec pod-sharing-demo -c nginx -- \
printenv CONTAINER_NAME
```

Output:

```text
NGINX
```

Now check debug:

```bash
kubectl exec pod-sharing-demo -c debug -- \
printenv CONTAINER_NAME
```

Output:

```text
DEBUG
```

### Conclusion

Each container has its own environment.

```text
nginx:
CONTAINER_NAME=NGINX

debug:
CONTAINER_NAME=DEBUG
```

Environment variables are **container-specific**.

---

# 8. PROOF #7 — Container Images Are Not Shared

The nginx container uses:

```yaml
image: nginx:alpine
```

The debug container uses:

```yaml
image: busybox:1.36
```

Check nginx:

```bash
kubectl exec pod-sharing-demo -c nginx -- ls /
```

Check debug:

```bash
kubectl exec pod-sharing-demo -c debug -- ls /
```

They have different root filesystems because each container is created from its own image.

For example:

```bash
kubectl exec pod-sharing-demo -c nginx -- nginx -v
```

works.

But:

```bash
kubectl exec pod-sharing-demo -c debug -- nginx -v
```

will fail because nginx isn't installed in the BusyBox container.

---

# 9. PROOF #8 — Process Namespace Is Normally NOT Shared

By default, containers in a Pod have separate process namespaces.

Check processes in nginx:

```bash
kubectl exec pod-sharing-demo -c nginx -- ps
```

Check processes in debug:

```bash
kubectl exec pod-sharing-demo -c debug -- ps
```

You will generally see different process views.

For example:

```text
nginx container

PID  COMMAND
1    nginx
...
```

while:

```text
debug container

PID  COMMAND
1    sh
...
```

Therefore:

```text
Container 1
PID namespace
     │
     └── nginx

Container 2
PID namespace
     │
     └── sh
```

are separate by default.

---

# 10. Optional Advanced Demo — Share the Process Namespace

Kubernetes allows:

```yaml
shareProcessNamespace: true
```

Example:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: process-sharing-demo

spec:

  shareProcessNamespace: true

  containers:

    - name: nginx
      image: nginx:alpine

    - name: debug
      image: busybox:1.36
      command:
        - sh
        - -c
        - sleep 3600
```

Create:

```bash
kubectl apply -f process-sharing-demo.yaml
```

Now:

```bash
kubectl exec process-sharing-demo -c debug -- ps
```

The debug container can see processes belonging to nginx.

For example:

```text
PID   COMMAND

1     /pause
...
nginx
nginx
```

### Important

This is **not enabled by default**.

```text
shareProcessNamespace: true
```

explicitly enables process namespace sharing.

---

# 11. What About CPU and Memory?

Containers inside a Pod do **not automatically share resource limits**.

Resource requests/limits are defined per container.

Example:

```yaml
containers:

- name: nginx
  image: nginx
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "256Mi"

- name: debug
  image: busybox
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"
```

The Pod has two containers with their own resource settings.

```text
Pod
│
├── nginx
│   ├── CPU limit: 500m
│   └── Memory limit: 256Mi
│
└── debug
    ├── CPU limit: 200m
    └── Memory limit: 128Mi
```

---

# 12. Final Verification Table

| Feature | Shared? | How to Prove |
|---|---:|---|
| Pod IP | ✅ | `hostname -i` |
| Network namespace | ✅ | Same IP / localhost |
| `localhost` | ✅ | `wget localhost:80` |
| Network ports | ✅ | Same port namespace |
| Shared volume | ✅ | Write/read `/shared` |
| Root filesystem | ❌ | `/tmp` file test |
| Environment variables | ❌ | `printenv` |
| Container image | ❌ | nginx vs busybox |
| Process namespace | ❌ Normally | `ps` |
| Process namespace | ✅ Optional | `shareProcessNamespace: true` |
| CPU limits | ❌ Per container | `resources.limits` |
| Memory limits | ❌ Per container | `resources.limits` |

---

# 13. One-Line Interview Explanation

> **Containers in the same Kubernetes Pod share the Pod's network namespace and can share volumes, but they normally have separate root filesystems, environment variables, and process namespaces.**

---

# 14. The Most Important Concept

Think of a Pod as:

```text
                    POD
                     │
          ┌──────────┴──────────┐
          │                     │
    Container A            Container B
          │                     │
          └──────────┬──────────┘
                     │
              Shared Network
              Shared localhost
              Shared Pod IP
                     │
               Shared Volumes
                if mounted
```

But:

```text
Container A                 Container B
────────────                 ────────────
Own filesystem               Own filesystem
Own environment              Own environment
Own container image          Own container image
Own process namespace*       Own process namespace*
Own resource limits          Own resource limits

* unless explicitly configured
```

---

# 15. Cleanup

Delete the demo:

```bash
kubectl delete pod pod-sharing-demo
```

Delete the process namespace demo:

```bash
kubectl delete pod process-sharing-demo
```

---

# 16. Teaching Challenge

After completing the demo, ask students:

### Question 1

If Container A writes:

```text
/tmp/file.txt
```

Can Container B read it?

**Answer:** ❌ No.

### Question 2

If Container A writes:

```text
/shared/file.txt
```

and both containers mount `/shared`, can Container B read it?

**Answer:** ✅ Yes.

### Question 3

Can Container B access Container A using:

```text
localhost
```

?

**Answer:** ✅ Yes.

### Question 4

Do both containers have the same Pod IP?

**Answer:** ✅ Yes.

### Question 5

Can both containers listen on:

```text
localhost:8080
```

simultaneously?

**Answer:** ❌ No, because they share the same network namespace.

### Question 6

Can Container B normally see Container A's processes?

**Answer:** ❌ No.

### Question 7

How can we make Container B see Container A's processes?

**Answer:**

```yaml
shareProcessNamespace: true
```

---

# Final Mental Model

```text
                    Kubernetes Pod
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
    Network           Volumes          Process
    Namespace         (if mounted)     Namespace
        │                │                │
        │                │          Separate normally
        │                │
        │                └────── Shared
        │
        └────── Shared
              │
        ┌─────┴─────┐
        ▼           ▼
     Container   Container
        A           B

     Separate filesystems
     Separate environments
     Separate images
     Separate resource limits
```

**Key takeaway:**

> A Pod is the smallest Kubernetes unit for scheduling, and its containers are designed to work closely together by sharing networking and, when configured, storage. They do **not** automatically share everything.