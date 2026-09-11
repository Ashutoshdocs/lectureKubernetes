# Kubernetes API Server Information Using kubectl

## Objective

This practical teaches how to inspect the Kubernetes API Server using `kubectl`.

You will learn how to:

- Check whether the Kubernetes cluster is reachable.
- Check the Kubernetes API Server version.
- Check API Server health.
- Find the API Server endpoint used by `kubectl`.
- Understand what happens when `kubectl` communicates with the API Server.

---

# 1. Kubernetes API Server

The **Kubernetes API Server** is the central communication point of a Kubernetes cluster.

When you execute:

```bash
kubectl get pods
```

the flow is approximately:

```text
User
 |
 | kubectl command
 v
kubectl
 |
 | Reads ~/.kube/config
 v
Kubernetes API Server
 |
 +----> Authentication
 |
 +----> Authorization
 |
 +----> Admission
 |
 v
Kubernetes resources
```

`kubectl` does not directly communicate with Pods, Deployments, Services, etc.

Instead, it sends API requests to the **Kubernetes API Server**.

---

# 2. Check Cluster Information

Run:

```bash
kubectl cluster-info
```

Example:

```text
Kubernetes control plane is running at https://10.10.1.5:6443
CoreDNS is running at https://10.10.1.5:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

## What does this command tell us?

It provides high-level information about the Kubernetes cluster and the control-plane endpoint.

The important part is:

```text
https://10.10.1.5:6443
```

Here:

| Part | Meaning |
|---|---|
| `https` | API Server communication uses HTTPS |
| `10.10.1.5` | API Server host/IP |
| `6443` | Default Kubernetes API Server secure port |

---

# 3. Check Kubernetes API Server Version

Run:

```bash
kubectl get --raw='/version'
```

Example:

```json
{
  "major": "1",
  "minor": "34",
  "gitVersion": "v1.34.11"
}
```

## What is `/version`?

`/version` is an API endpoint exposed by the Kubernetes API Server.

The command:

```bash
kubectl get --raw='/version'
```

means:

> Send a raw HTTP GET request to the `/version` API endpoint.

The API Server returns version information.

For example:

```text
gitVersion = v1.34.11
```

means the Kubernetes API Server is running Kubernetes version `1.34.11`.

---

# 4. Check API Server Liveness

Run:

```bash
kubectl get --raw='/livez'
```

If the API Server is healthy, you should normally see:

```text
ok
```

## Meaning of `livez`

`livez` asks:

> Is the API Server alive?

Think of it as:

```text
kubectl
   |
   | GET /livez
   v
API Server
   |
   v
ok
```

If this request succeeds, the API Server is reachable and responding to the request.

---

# 5. Check the API Server Endpoint Used by kubectl

Run:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

Example output:

```text
https://20.12.239.56:6443
```

This is extremely useful for troubleshooting.

It tells you:

> Which Kubernetes API Server endpoint is the current kubectl context configured to use?

---

# 6. Understand kubeconfig

`kubectl` normally gets its cluster connection information from:

```text
~/.kube/config
```

The kubeconfig contains information similar to:

```yaml
clusters:
- cluster:
    server: https://20.12.239.56:6443
```

The important field is:

```yaml
server: https://20.12.239.56:6443
```

This tells `kubectl` where the Kubernetes API Server is located.

It also contains authentication information, such as:

```yaml
users:
- name: kubernetes-admin
  user:
    client-certificate-data: ...
    client-key-data: ...
```

Therefore:

```text
kubectl
 |
 | 1. Read ~/.kube/config
 |
 | 2. Find server endpoint
 |
 | 3. Find credentials
 |
 v
API Server
```

---

# 7. Four Important Commands

Run these commands one by one:

```bash
kubectl cluster-info
```

```bash
kubectl get --raw='/version'
```

```bash
kubectl get --raw='/livez'
```

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

---

# 8. What Each Command Answers

| Command | Main Question |
|---|---|
| `kubectl cluster-info` | Where is my Kubernetes control plane? |
| `kubectl get --raw='/version'` | What version is the API Server running? |
| `kubectl get --raw='/livez'` | Is the API Server alive and responding? |
| `kubectl config view --minify ...` | Which API Server endpoint is my current kubectl context using? |

---

# 9. Practical Troubleshooting Example

Suppose you run:

```bash
kubectl get nodes
```

and receive:

```text
The connection to the server 20.12.239.56:6443 was refused
```

Do not immediately assume that the Kubernetes cluster is completely broken.

First check:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

If the result is:

```text
https://20.12.239.56:6443
```

then `kubectl` is trying to contact:

```text
20.12.239.56:6443
```

Next:

```bash
kubectl cluster-info
```

Then:

```bash
kubectl get --raw='/version'
```

Then:

```bash
kubectl get --raw='/livez'
```

These commands help separate different problems.

---

# 10. Important Difference: Authentication vs Connectivity

Suppose you see:

```text
connection refused
```

This is generally a **connectivity/API endpoint problem**, not an RBAC permission problem.

Compare:

### Case 1: Connection refused

```text
kubectl
   |
   X
API Server
```

Example:

```text
dial tcp 20.12.239.56:6443: connect: connection refused
```

The client could not establish the TCP connection.

### Case 2: Unauthorized

```text
kubectl
   |
   | HTTPS connection works
   v
API Server
   |
   X Authentication failed
```

Example:

```text
Unauthorized
```

### Case 3: Forbidden

```text
kubectl
   |
   | Authentication succeeds
   v
API Server
   |
   | RBAC
   v
Forbidden
```

Example:

```text
Error from server (Forbidden)
```

This means the user was authenticated but does not have permission for the requested operation.

---

# 11. Three Different Questions

When troubleshooting Kubernetes access, remember:

```text
1. CAN I REACH THE API SERVER?
              |
              v
        Connectivity

2. WHO AM I?
              |
              v
        Authentication

3. WHAT CAN I DO?
              |
              v
        Authorization / RBAC
```

For example:

```text
kubectl
   |
   | HTTPS
   v
API Server
   |
   +--> Connectivity
   |
   +--> Authentication
   |       |
   |       +--> Certificate
   |       +--> Token
   |       +--> OIDC
   |
   +--> Authorization
           |
           +--> RBAC
```

---

# 12. Lab Exercise

Run:

```bash
kubectl cluster-info
```

Record the API Server address.

Then:

```bash
kubectl get --raw='/version'
```

Record the Kubernetes version.

Then:

```bash
kubectl get --raw='/livez'
```

Confirm that the API Server responds:

```text
ok
```

Finally:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

Record the endpoint.

---

# 13. Expected Learning Outcome

After this practical, you should be able to explain:

> `kubectl` reads the current cluster and authentication information from kubeconfig, connects to the configured Kubernetes API Server, and sends API requests over HTTPS.

You should also understand these four commands:

```bash
kubectl cluster-info
kubectl get --raw='/version'
kubectl get --raw='/livez'
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

The most important troubleshooting idea is:

```text
Connection refused
        ↓
Check API Server endpoint
        ↓
Check whether API Server is reachable
        ↓
Then investigate authentication
        ↓
Then investigate authorization/RBAC
```

---

# Quick Reference

```bash
# Cluster/control-plane information
kubectl cluster-info

# Kubernetes API Server version
kubectl get --raw='/version'

# API Server liveness
kubectl get --raw='/livez'

# API Server endpoint configured for current kubectl context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```
