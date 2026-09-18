# Kubernetes Pods — Create, Enter, Describe & Debug

A practical guide for teaching how to create Pods in different ways, enter containers, work with multi-container Pods, inspect Pods, and retrieve logs from specific containers.

---

# 1. What Is a Pod?

A **Pod** is the smallest deployable unit in Kubernetes.

A Pod can contain:

```text
Pod
 ├── Container 1
 ├── Container 2
 └── Container 3
```

Usually, a Pod contains one main application container.

A Pod can also contain multiple containers when those containers need to:

- Share the same network namespace
- Share storage volumes
- Work closely together
- Implement a sidecar pattern

---

# 2. Different Ways to Create a Pod

There are several common ways to create Pods.

## Method 1 — `kubectl run`

The quickest way to create a simple Pod:

```bash
kubectl run nginx --image=nginx
```

Check it:

```bash
kubectl get pods
```

Detailed information:

```bash
kubectl get pod nginx -o wide
```

---

## Method 2 — Create a Pod using YAML

Create a file:

```bash
vim pod.yaml
```

Example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
spec:
  containers:
    - name: nginx
      image: nginx
```

Create it:

```bash
kubectl apply -f pod.yaml
```

or:

```bash
kubectl create -f pod.yaml
```

Check:

```bash
kubectl get pods
```

### Why use YAML?

YAML is preferred when you need to define:

- Environment variables
- Ports
- Volumes
- Resource requests/limits
- Probes
- Multiple containers
- Security settings
- Commands/arguments
- Labels and annotations

---

# 3. Generate YAML Without Creating the Pod

A very useful technique:

```bash
kubectl run nginx \
  --image=nginx \
  --dry-run=client \
  -o yaml
```

This generates the YAML instead of creating the Pod.

Save it:

```bash
kubectl run nginx \
  --image=nginx \
  --dry-run=client \
  -o yaml > nginx.yaml
```

Then inspect:

```bash
cat nginx.yaml
```

Create:

```bash
kubectl apply -f nginx.yaml
```

### Teaching point

Think:

```text
kubectl run
    ↓
--dry-run=client
    ↓
Do NOT create
    ↓
-o yaml
    ↓
Give me the YAML
```

This is extremely useful for quickly generating starter manifests.

---

# 4. Create a Pod with a Specific Command

Example:

```bash
kubectl run mypod \
  --image=busybox \
  --command -- sleep 3600
```

The `--command` portion means the following arguments become the container's command.

Check:

```bash
kubectl get pod mypod
```

Describe:

```bash
kubectl describe pod mypod
```

---

# 5. Create an Interactive Pod

For troubleshooting, you may want a Pod that stays alive:

```bash
kubectl run debug-pod \
  --image=busybox \
  --command -- sleep 3600
```

Then enter it:

```bash
kubectl exec -it debug-pod -- sh
```

This is a very common Kubernetes troubleshooting technique.

---

# 6. Understanding `kubectl exec`

The basic syntax is:

```bash
kubectl exec -it <pod-name> -- <command>
```

Example:

```bash
kubectl exec -it nginx -- /bin/bash
```

Meaning:

```text
kubectl
   ↓
exec
   ↓
execute something inside the Pod
   ↓
-i
keep STDIN open
   ↓
-t
allocate a terminal
   ↓
-- 
separates kubectl options from the command
   ↓
/bin/bash
shell to execute
```

---

# 7. Go Inside a Pod

If the container has Bash:

```bash
kubectl exec -it nginx -- /bin/bash
```

If Bash does not exist:

```bash
kubectl exec -it nginx -- /bin/sh
```

Once inside:

```bash
hostname
```

```bash
ls
```

```bash
pwd
```

```bash
env
```

Exit:

```bash
exit
```

---

# 8. `sh` vs `bash`

This is a very important troubleshooting concept.

Not every container image contains Bash.

For example:

```text
Ubuntu
 ├── /bin/sh
 └── /bin/bash

Debian
 ├── /bin/sh
 └── /bin/bash

Alpine
 ├── /bin/sh
 └── often no Bash by default

BusyBox
 └── /bin/sh
```

Therefore:

```bash
kubectl exec -it pod -- /bin/bash
```

may fail with something like:

```text
exec: "/bin/bash": stat /bin/bash: no such file or directory
```

Try:

```bash
kubectl exec -it pod -- /bin/sh
```

---

# 9. How Do I Know Which Shell Exists?

There are several ways to determine this.

## Method 1 — Try Bash

```bash
kubectl exec -it mypod -- /bin/bash
```

If it fails because Bash doesn't exist, try:

```bash
kubectl exec -it mypod -- /bin/sh
```

---

## Method 2 — Check Common Shell Locations

If you can execute a basic command:

```bash
kubectl exec mypod -- ls /bin
```

Look for:

```text
sh
bash
ash
```

For example:

```text
/bin
 ├── sh
 ├── ash
 ├── ls
 ├── cat
 └── ...
```

Then:

```bash
kubectl exec -it mypod -- /bin/ash
```

may work.

---

## Method 3 — Check `/etc/shells`

If available:

```bash
kubectl exec mypod -- cat /etc/shells
```

You may see:

```text
/bin/sh
/bin/bash
```

However, **do not assume `/etc/shells` exists in every minimal container image**.

---

## Method 4 — Inspect the Image

Check the image:

```bash
kubectl get pod mypod \
  -o jsonpath='{.spec.containers[*].image}'
```

Then check that image's documentation or image contents if necessary.

---

# 10. Important: Kubernetes Does Not Choose the Shell

This is a key concept.

Kubernetes does **not** decide:

```text
"Every container gets Bash."
```

The shell is part of the container image.

For example:

```text
nginx image
     ↓
filesystem
     ↓
contains certain executables
     ↓
maybe /bin/sh
     ↓
maybe /bin/bash
```

So:

```bash
kubectl exec -it pod -- /bin/bash
```

works **only if `/bin/bash` exists inside that container**.

---

# 11. Go Inside a Pod in a Particular Namespace

If the Pod is in another namespace:

```bash
kubectl exec -it nginx -n dev -- /bin/sh
```

General pattern:

```bash
kubectl exec -it <pod> -n <namespace> -- /bin/sh
```

---

# 12. Multi-Container Pods

A Pod can contain multiple containers.

Example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi-container-pod
spec:
  containers:

    - name: nginx
      image: nginx

    - name: sidecar
      image: busybox
      command:
        - sh
        - -c
        - "while true; do echo sidecar-running; sleep 5; done"
```

Create:

```bash
kubectl apply -f multi-container.yaml
```

Check:

```bash
kubectl get pod multi-container-pod
```

You should see:

```text
READY
2/2
```

Meaning:

```text
2 containers
2 containers ready
```

---

# 13. See All Containers in a Pod

Use:

```bash
kubectl get pod multi-container-pod \
  -o jsonpath='{.spec.containers[*].name}'
```

Example output:

```text
nginx sidecar
```

Another useful command:

```bash
kubectl describe pod multi-container-pod
```

Look under:

```text
Containers:
```

You may see:

```text
Containers:
  nginx:
    Image: nginx

  sidecar:
    Image: busybox
```

---

# 14. Why Does Multi-Container Pod Need Special Handling?

Suppose:

```text
Pod
 ├── nginx
 └── sidecar
```

If you execute:

```bash
kubectl exec -it multi-container-pod -- /bin/sh
```

Kubernetes needs to know **which container** you mean.

If the Pod has multiple containers, Kubernetes may use the default container behavior if one is configured, or otherwise select a container according to kubectl's rules.

For teaching and scripts, **explicitly specifying the container is clearer and safer**.

---

# 15. Enter a Specific Container

Use:

```bash
kubectl exec -it multi-container-pod \
  -c nginx \
  -- /bin/sh
```

For the sidecar:

```bash
kubectl exec -it multi-container-pod \
  -c sidecar \
  -- /bin/sh
```

The important option is:

```bash
-c <container-name>
```

or:

```bash
--container=<container-name>
```

---

# 16. Multi-Container Mental Model

Think:

```text
                    POD
                     │
          ┌──────────┴──────────┐
          │                     │
       nginx                 sidecar
          │                     │
      /bin/sh                /bin/sh
```

Command:

```bash
kubectl exec -it multi-container-pod -c nginx -- /bin/sh
```

means:

```text
Pod
 ↓
multi-container-pod
 ↓
container
 ↓
nginx
 ↓
execute
 ↓
/bin/sh
```

---

# 17. Run a Command Without Opening a Shell

You don't always need an interactive shell.

Example:

```bash
kubectl exec nginx -- hostname
```

Check environment:

```bash
kubectl exec nginx -- env
```

List files:

```bash
kubectl exec nginx -- ls /
```

Check processes:

```bash
kubectl exec nginx -- ps
```

For a specific container:

```bash
kubectl exec multi-container-pod \
  -c nginx \
  -- ls /
```

This is useful in scripts and troubleshooting.

---

# 18. Understand `-i` and `-t`

Common command:

```bash
kubectl exec -it nginx -- /bin/sh
```

### `-i`

Interactive.

Keeps standard input open.

### `-t`

Allocates a terminal.

Together:

```bash
-it
```

are commonly used for an interactive shell.

Without them:

```bash
kubectl exec nginx -- ls /
```

is appropriate for a simple command.

---

# 19. Describe a Pod

Use:

```bash
kubectl describe pod nginx
```

This is one of the most important troubleshooting commands.

It provides information such as:

- Pod metadata
- Namespace
- Node
- IP address
- Container information
- Images
- Commands
- Environment
- Mounts
- Conditions
- Container states
- Restart counts
- Events

---

# 20. Understand the `describe` Output

A typical structure looks like:

```text
Name:
Namespace:
Priority:
Node:
Start Time:
Labels:
Annotations:
Status:
IP:
Containers:
  nginx:
    Container ID:
    Image:
    Image ID:
    Port:
    State:
    Ready:
    Restart Count:

Conditions:
Volumes:
QoS Class:
Events:
```

The bottom **Events** section is particularly valuable during troubleshooting.

---

# 21. `get` vs `describe`

### `get`

```bash
kubectl get pod nginx
```

Good for:

> "What is the current high-level status?"

Example:

```text
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          2m
```

### `describe`

```bash
kubectl describe pod nginx
```

Good for:

> "Tell me detailed information about this Pod and what happened to it."

Think:

```text
get       → quick overview
describe  → detailed troubleshooting information
```

---

# 22. Get Pod YAML

Another very useful command:

```bash
kubectl get pod nginx -o yaml
```

This shows the complete Kubernetes object representation.

Compare:

```bash
kubectl get pod nginx
```

```text
short view
```

with:

```bash
kubectl describe pod nginx
```

```text
human-friendly diagnostic view
```

and:

```bash
kubectl get pod nginx -o yaml
```

```text
complete object configuration + current state
```

---

# 23. View Pod Logs

Basic command:

```bash
kubectl logs nginx
```

This shows logs from the container.

---

# 24. Logs from a Specific Container

For a multi-container Pod:

```bash
kubectl logs multi-container-pod -c nginx
```

Sidecar:

```bash
kubectl logs multi-container-pod -c sidecar
```

Equivalent long form:

```bash
kubectl logs multi-container-pod \
  --container=nginx
```

---

# 25. Why Specify the Container for Logs?

Suppose:

```text
Pod
 ├── nginx
 └── sidecar
```

Each container has its own stdout/stderr stream.

Therefore:

```bash
kubectl logs multi-container-pod -c nginx
```

means:

```text
Pod
 ↓
nginx container
 ↓
show its logs
```

while:

```bash
kubectl logs multi-container-pod -c sidecar
```

means:

```text
Pod
 ↓
sidecar container
 ↓
show its logs
```

---

# 26. Follow Logs in Real Time

Use:

```bash
kubectl logs -f nginx
```

`-f` means:

```text
follow
```

For a specific container:

```bash
kubectl logs -f multi-container-pod -c sidecar
```

This is similar to:

```bash
tail -f
```

for a continuously updating log stream.

---

# 27. Show Previous Container Logs

Very important for crash troubleshooting.

If a container has restarted:

```bash
kubectl logs nginx --previous
```

For a specific container:

```bash
kubectl logs multi-container-pod \
  -c nginx \
  --previous
```

This asks Kubernetes for logs from the **previous terminated container instance**, when available.

---

# 28. Useful Log Options

### Show timestamps

```bash
kubectl logs nginx --timestamps
```

### Show the last 100 lines

```bash
kubectl logs nginx --tail=100
```

### Show logs from the last 10 minutes

```bash
kubectl logs nginx --since=10m
```

### Follow logs

```bash
kubectl logs -f nginx
```

### Previous container instance

```bash
kubectl logs nginx --previous
```

---

# 29. Logs + Describe = Powerful Combination

Suppose a Pod is restarting.

Start with:

```bash
kubectl get pod mypod
```

Then:

```bash
kubectl describe pod mypod
```

Look at:

```text
State
Last State
Restart Count
Events
```

Then:

```bash
kubectl logs mypod
```

If it restarted:

```bash
kubectl logs mypod --previous
```

For a multi-container Pod:

```bash
kubectl logs mypod -c <container-name> --previous
```

---

# 30. How to Discover the Container Name

Use:

```bash
kubectl get pod mypod \
  -o jsonpath='{.spec.containers[*].name}'
```

Example:

```text
nginx sidecar
```

Then:

```bash
kubectl logs mypod -c nginx
```

or:

```bash
kubectl exec -it mypod -c sidecar -- /bin/sh
```

---

# 31. Discover Container Names with `describe`

Run:

```bash
kubectl describe pod mypod
```

Look for:

```text
Containers:
  nginx:
    Image: nginx

  sidecar:
    Image: busybox
```

Container names:

```text
nginx
sidecar
```

Then use:

```bash
-c nginx
```

or:

```bash
-c sidecar
```

---

# 32. Discover Containers Using `get`

Useful command:

```bash
kubectl get pod mypod \
  -o custom-columns=NAME:.metadata.name,CONTAINERS:.spec.containers[*].name
```

Example:

```text
NAME   CONTAINERS
mypod  nginx,sidecar
```

This is convenient when you only want the important fields.

---

# 33. Discover Shell + Container Together

For a multi-container Pod, first find containers:

```bash
kubectl get pod mypod \
  -o jsonpath='{.spec.containers[*].name}'
```

Then inspect each image:

```bash
kubectl get pod mypod \
  -o jsonpath='{range .spec.containers[*]}{.name}{" -> "}{.image}{"\n"}{end}'
```

Example:

```text
nginx -> nginx:latest
sidecar -> busybox:latest
```

Then choose an appropriate shell based on the image.

For example:

```bash
kubectl exec -it mypod -c nginx -- /bin/sh
```

```bash
kubectl exec -it mypod -c sidecar -- /bin/sh
```

If `/bin/sh` does not exist, investigate the image for another available shell.

---

# 34. What If the Container Has No Shell?

This is a very important real-world scenario.

Some minimal or hardened container images may contain **no shell at all**.

For example:

```text
Application container
 ├── application binary
 ├── libraries
 └── no /bin/sh
     no /bin/bash
```

Then:

```bash
kubectl exec -it mypod -- /bin/sh
```

fails.

That does **not necessarily mean the Pod is broken**.

It may simply mean:

> The image intentionally does not contain a shell.

---

# 35. What Do You Do If There Is No Shell?

You can still execute binaries that exist in the container:

```bash
kubectl exec mypod -- <available-command>
```

But if the image is extremely minimal, even basic troubleshooting commands may be absent.

In such cases, Kubernetes provides another troubleshooting technique: **ephemeral containers**.

Example concept:

```bash
kubectl debug -it mypod \
  --image=busybox \
  --target=<container-name>
```

The exact behavior depends on the cluster/runtime configuration and Kubernetes version.

The important teaching idea is:

```text
No shell in application image
             ↓
Don't assume image is broken
             ↓
Use appropriate debugging tools
             ↓
Ephemeral debug container can provide
a troubleshooting environment
```

---

# 36. Multi-Container Pod Example

Create:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod
spec:
  containers:

    - name: web
      image: nginx

    - name: logger
      image: busybox
      command:
        - sh
        - -c
        - |
          while true; do
            echo "logger container is alive"
            sleep 5
          done
```

Apply:

```bash
kubectl apply -f demo-pod.yaml
```

Check:

```bash
kubectl get pod demo-pod
```

Expected:

```text
NAME       READY   STATUS    RESTARTS   AGE
demo-pod   2/2     Running   0          ...
```

---

# 37. Enter the Web Container

```bash
kubectl exec -it demo-pod \
  -c web \
  -- /bin/sh
```

Inside:

```bash
ls /usr/share/nginx/html
```

Then:

```bash
exit
```

---

# 38. Enter the Logger Container

```bash
kubectl exec -it demo-pod \
  -c logger \
  -- /bin/sh
```

Inside:

```bash
ps
```

Then:

```bash
exit
```

---

# 39. Check Logs of Web Container

```bash
kubectl logs demo-pod -c web
```

---

# 40. Check Logs of Logger Container

```bash
kubectl logs demo-pod -c logger
```

You should see messages similar to:

```text
logger container is alive
logger container is alive
logger container is alive
```

Follow them:

```bash
kubectl logs -f demo-pod -c logger
```

---

# 41. Describe the Multi-Container Pod

```bash
kubectl describe pod demo-pod
```

Look at:

```text
Containers:
  web:
    Image: nginx
    State: Running

  logger:
    Image: busybox
    State: Running
```

And at the bottom:

```text
Events:
```

---

# 42. Complete Troubleshooting Workflow

When someone says:

> "My Kubernetes Pod is not working."

Use this workflow.

### Step 1 — Check Pod status

```bash
kubectl get pods
```

---

### Step 2 — Get more detail

```bash
kubectl get pod <pod-name> -o wide
```

---

### Step 3 — Describe

```bash
kubectl describe pod <pod-name>
```

Check:

```text
State
Last State
Reason
Message
Restart Count
Events
```

---

### Step 4 — Check logs

Single-container Pod:

```bash
kubectl logs <pod-name>
```

Multi-container Pod:

```bash
kubectl logs <pod-name> -c <container-name>
```

---

### Step 5 — If it restarted

```bash
kubectl logs <pod-name> --previous
```

or:

```bash
kubectl logs <pod-name> \
  -c <container-name> \
  --previous
```

---

### Step 6 — Enter the container

Try:

```bash
kubectl exec -it <pod-name> -c <container-name> -- /bin/sh
```

If unavailable:

```bash
kubectl exec -it <pod-name> -c <container-name> -- /bin/bash
```

or investigate which shell/binary exists.

---

# 43. Quick Decision Tree

```text
             Pod problem?
                  │
                  ▼
        kubectl get pods
                  │
          ┌───────┴───────┐
          │               │
       Running?          No
          │               │
          ▼               ▼
      Check logs      describe pod
          │               │
          ▼               ▼
   kubectl logs       Check Events
          │               │
          ▼               ▼
      Need shell?     Find root cause
          │
          ▼
   kubectl exec -it
          │
          ▼
      /bin/sh ?
          │
     ┌────┴────┐
     │         │
    Yes        No
     │         │
     ▼         ▼
   Enter    Try /bin/bash
               │
               ▼
        If no shell exists
               │
               ▼
        Use debugging tools
```

---

# 44. Command Cheat Sheet

## Create

```bash
kubectl run nginx --image=nginx
```

```bash
kubectl apply -f pod.yaml
```

```bash
kubectl run nginx --image=nginx --dry-run=client -o yaml
```

---

## List

```bash
kubectl get pods
```

```bash
kubectl get pods -o wide
```

```bash
kubectl get pods -A
```

---

## Describe

```bash
kubectl describe pod nginx
```

---

## YAML

```bash
kubectl get pod nginx -o yaml
```

---

## Enter Pod / Container

```bash
kubectl exec -it nginx -- /bin/sh
```

```bash
kubectl exec -it nginx -- /bin/bash
```

```bash
kubectl exec -it mypod -c nginx -- /bin/sh
```

---

## Execute a command

```bash
kubectl exec nginx -- ls /
```

```bash
kubectl exec mypod -c nginx -- env
```

---

## Find containers

```bash
kubectl get pod mypod \
  -o jsonpath='{.spec.containers[*].name}'
```

---

## Logs

```bash
kubectl logs nginx
```

```bash
kubectl logs mypod -c nginx
```

```bash
kubectl logs -f mypod -c nginx
```

```bash
kubectl logs mypod -c nginx --previous
```

```bash
kubectl logs mypod -c nginx --timestamps
```

```bash
kubectl logs mypod -c nginx --tail=100
```

---

# 45. The Most Important Concepts to Remember

### 1. Pod is the execution unit

```text
Pod
 └── one or more containers
```

### 2. `kubectl exec` executes inside a container

```bash
kubectl exec -it <pod> -- <command>
```

### 3. `-c` selects the container

```bash
kubectl exec -it <pod> -c <container> -- /bin/sh
```

### 4. Shell belongs to the image

Kubernetes does not automatically install Bash or Sh.

### 5. `describe` is for investigation

```bash
kubectl describe pod <pod>
```

### 6. Logs belong to containers

For multiple containers:

```bash
kubectl logs <pod> -c <container>
```

### 7. `--previous` is extremely useful for crashes

```bash
kubectl logs <pod> -c <container> --previous
```

### 8. No shell does not necessarily mean broken

Minimal production images may intentionally contain no shell.

---

# 46. One-Look Summary

```text
CREATE
  │
  ├── kubectl run
  └── kubectl apply -f YAML
          │
          ▼
       POD
          │
          ├───────────────┐
          ▼               ▼
     DESCRIBE           LOGS
          │               │
          │          ┌────┴────┐
          │          │         │
          │       container   previous
          │
          ▼
       EVENTS
          │
          ▼
     TROUBLESHOOT
          │
          ▼
        EXEC
          │
          ▼
   choose container (-c)
          │
          ▼
      choose shell
    /bin/sh /bin/bash
          │
          ▼
   WORK INSIDE CONTAINER
```

> **Core formula for Kubernetes Pod troubleshooting:**

```text
GET → DESCRIBE → LOGS → EXEC
```

Use:

```bash
kubectl get pod <pod>
kubectl describe pod <pod>
kubectl logs <pod> [-c <container>]
kubectl exec -it <pod> [-c <container>] -- /bin/sh
```

This sequence should become second nature when working with Kubernetes Pods.
