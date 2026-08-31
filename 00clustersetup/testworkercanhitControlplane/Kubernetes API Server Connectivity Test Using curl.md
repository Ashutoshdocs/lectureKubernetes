# Kubernetes API Server Connectivity Test Using curl

## Objective

This demo shows how to verify that a **Kubernetes worker node can communicate with the Kubernetes API Server** using `curl`.

We will prove:

1. The API Server is running.
2. The worker node can reach the API Server.
3. TCP port `6443` is accessible.
4. HTTPS communication with the API Server works.
5. API connectivity is different from Kubernetes authentication and authorization.

---

# Lab Architecture

In this demo we have:

```text
                    Kubernetes Cluster

              CONTROL PLANE
              172.30.1.2
                   │
                   │
             API Server
             HTTPS :6443
                   ▲
                   │
                   │ HTTPS
                   │
             WORKER NODE
                node01
```

The Kubernetes API Server is available at:

```text
https://172.30.1.2:6443
```

---

# Prerequisites

On the control plane:

```bash
kubectl cluster-info
```

Expected:

```text
Kubernetes control plane is running at https://172.30.1.2:6443
CoreDNS is running at ...
```

Check the API Server IP:

```bash
kubectl cluster-info
```

---

# Step 1 — Verify API Server From Control Plane

Run on the **control plane**:

```bash
curl -k https://172.30.1.2:6443/version
```

Expected output will contain Kubernetes version information similar to:

```json
{
  "major": "1",
  "minor": "30",
  "gitVersion": "v1.30.x"
}
```

This proves that the API Server is responding.

---

# Step 2 — Test From Worker Node

SSH into the worker:

```bash
ssh root@node01
```

Run:

```bash
curl -k https://172.30.1.2:6443/version
```

If you receive Kubernetes version information, the worker can communicate with the API Server.

Example:

```json
{
  "major": "1",
  "minor": "30",
  "gitVersion": "v1.30.x"
}
```

---

# What Does This Prove?

Successful execution:

```bash
curl -k https://172.30.1.2:6443/version
```

from the worker proves:

```text
Worker Node
     │
     │ HTTPS
     │ TCP 6443
     ▼
172.30.1.2
     │
     ▼
Kubernetes API Server
     │
     ▼
Response
```

Therefore:

| Test | Result |
|---|---|
| Worker → Control Plane connectivity | ✅ |
| TCP port 6443 reachable | ✅ |
| API Server reachable | ✅ |
| HTTPS connection established | ✅ |
| API Server responding | ✅ |
| Kubernetes authentication | Not tested |
| Kubernetes authorization | Not tested |

---

# What Does `-k` Mean?

The command is:

```bash
curl -k https://172.30.1.2:6443/version
```

The `-k` option means:

```text
-k = insecure
```

It tells `curl` to skip TLS certificate verification.

This is useful for a quick connectivity test because the Kubernetes API Server commonly uses certificates that are not trusted by the operating system's default CA store.

Therefore:

```bash
curl -k
```

means:

> Connect using HTTPS but don't verify whether the server certificate is trusted.

---

# Step 3 — Test API Server Health

From the worker node:

```bash
curl -k https://172.30.1.2:6443/healthz
```

Expected:

```text
ok
```

This confirms that the API Server health endpoint is responding.

---

# Step 4 — Test the Kubernetes API

Run:

```bash
curl -k https://172.30.1.2:6443/api
```

You should receive information about the Kubernetes API.

You can also test:

```bash
curl -k https://172.30.1.2:6443/apis
```

---

# Step 5 — Test a Protected API Endpoint

Now try:

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

You may receive:

```json
{
  "kind": "Status",
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

This is expected.

Why?

Because the request is reaching the API Server, but `curl` has not supplied valid Kubernetes credentials.

---

# Important Concept

There is a difference between:

```text
Connectivity
```

and:

```text
Authentication
```

and:

```text
Authorization
```

## Connectivity

Can the worker reach the API Server?

```bash
curl -k https://172.30.1.2:6443/version
```

If successful:

```text
Connectivity ✅
```

---

## Authentication

Who are you?

For example:

```text
Certificate
Token
ServiceAccount token
```

Without credentials:

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

may return:

```text
401 Unauthorized
```

---

## Authorization

What are you allowed to do?

Even after successful authentication, Kubernetes checks RBAC permissions.

For example:

```text
User
 │
 ├── Authentication
 │       ↓
 │    Who are you?
 │
 └── Authorization
         ↓
      What can you do?
```

---

# Step 6 — Compare curl With kubectl

On the control plane:

```bash
kubectl get pods
```

works because `kubectl` uses credentials from the kubeconfig.

Check:

```bash
kubectl config view
```

The kubeconfig contains information such as:

```text
Cluster
Server
Certificate Authority
User credentials
Context
```

The API Server is:

```text
https://172.30.1.2:6443
```

---

# Step 7 — See kubectl Communicating With API Server

Run:

```bash
kubectl get pods -v=8
```

For even more detailed output:

```bash
kubectl get pods -v=9
```

You will see HTTP/API communication information.

Conceptually:

```text
kubectl
   │
   │ HTTPS request
   ▼
API Server :6443
   │
   ▼
Authentication
   │
   ▼
Authorization
   │
   ▼
Kubernetes API
```

---

# Step 8 — Check Port 6443 Directly

From the worker:

```bash
nc -zv 172.30.1.2 6443
```

Expected:

```text
Connection to 172.30.1.2 6443 port [tcp/*] succeeded!
```

If `nc` is not installed:

```bash
apt update
apt install netcat-openbsd -y
```

Then:

```bash
nc -zv 172.30.1.2 6443
```

---

# Troubleshooting

## Problem 1 — Connection Refused

Example:

```text
curl: (7) Failed to connect to 172.30.1.2 port 6443
```

Check the API Server on the control plane:

```bash
ss -lntp | grep 6443
```

You should see port `6443` listening.

---

## Problem 2 — Connection Timed Out

Example:

```text
curl: (28) Connection timed out
```

Possible causes:

```text
Firewall
NSG
Network ACL
Routing
Wrong IP
API Server not reachable
```

Test:

```bash
ping 172.30.1.2
```

Then:

```bash
nc -zv 172.30.1.2 6443
```

---

## Problem 3 — TLS Certificate Error

If you run:

```bash
curl https://172.30.1.2:6443/version
```

you may receive a certificate verification error.

For a quick lab test use:

```bash
curl -k https://172.30.1.2:6443/version
```

---

## Problem 4 — Unauthorized

If:

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

returns:

```text
401 Unauthorized
```

this does **not** mean the network is broken.

It means:

```text
Worker
  │
  │ HTTPS connection
  ▼
API Server
  │
  └── Request received
          │
          └── No valid credentials
                   ↓
                401
```

---

# Complete Demo

## Control Plane

Run:

```bash
kubectl cluster-info
```

Then:

```bash
curl -k https://172.30.1.2:6443/version
```

Then:

```bash
curl -k https://172.30.1.2:6443/healthz
```

---

## Worker Node

Run:

```bash
curl -k https://172.30.1.2:6443/version
```

Then:

```bash
curl -k https://172.30.1.2:6443/healthz
```

Then:

```bash
nc -zv 172.30.1.2 6443
```

Finally:

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

Observe the difference:

```text
/version
   ↓
Kubernetes version
   ↓
Connectivity works ✅


/healthz
   ↓
ok
   ↓
API Server reachable and healthy ✅


/api/v1/pods
   ↓
401 Unauthorized
   ↓
Authentication required
```

---

# Final Architecture

```text
                         Kubernetes Cluster

        ┌─────────────────────────────────────────┐
        │                                         │
        │           CONTROL PLANE                 │
        │           172.30.1.2                   │
        │                                         │
        │        kube-apiserver                   │
        │             │                           │
        │             │ HTTPS :6443               │
        │             │                           │
        └─────────────┼───────────────────────────┘
                      ▲
                      │
                      │
                Network Connection
                      │
                      │
        ┌─────────────┴───────────────────────────┐
        │                                         │
        │             WORKER NODE                 │
        │               node01                    │
        │                                         │
        │  curl -k https://172.30.1.2:6443/...   │
        │                                         │
        └─────────────────────────────────────────┘
```

---

# Key Takeaways

### 1. Kubernetes API Server

Default secure API Server port:

```text
6443
```

### 2. `/version`

```bash
curl -k https://172.30.1.2:6443/version
```

Tests API Server connectivity and returns version information.

### 3. `/healthz`

```bash
curl -k https://172.30.1.2:6443/healthz
```

Tests API Server health.

### 4. `/api/v1/pods`

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

Accesses a protected Kubernetes API resource and normally requires authentication.

### 5. Worker reaching API Server ≠ Worker authenticated

A successful:

```bash
curl -k https://172.30.1.2:6443/version
```

from the worker proves:

```text
Network connectivity ✅
API Server reachable ✅
Port 6443 accessible ✅
HTTPS communication ✅
```

It does **not** by itself prove:

```text
Authentication ❌
Authorization ❌
```

This distinction is important for **CKA/CKS troubleshooting** and for understanding Kubernetes control-plane networking.