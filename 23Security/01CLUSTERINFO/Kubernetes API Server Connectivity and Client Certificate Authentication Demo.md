# Kubernetes API Server Connectivity Test Using curl

## Objective

This demo shows how to verify that a **Kubernetes worker node can communicate with the Kubernetes API Server** using `curl`.

We will prove:

1. The API Server is running.
2. The worker node can reach the API Server.
3. TCP port `6443` is accessible.
4. HTTPS communication with the API Server works.
5. How Kubernetes client certificates can be extracted from kubeconfig.
6. How `ca.crt`, `admin.crt`, and `admin.key` have different purposes.
7. API connectivity is different from Kubernetes authentication and authorization.

---

# Lab Architecture

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

# Step 5 — Understand the Certificates Used by kubectl

Before testing certificate authentication with `curl`, inspect the current kubeconfig:

```bash
kubectl config view --minify
```

You may see:

```yaml
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://172.30.1.2:6443
  name: kubernetes

users:
- name: kubernetes-admin
  user:
    client-certificate-data: DATA+OMITTED
    client-key-data: DATA+OMITTED
```

This tells us that the certificates are embedded inside kubeconfig.

They are not necessarily stored as:

```text
/etc/kubernetes/pki/admin.crt
/etc/kubernetes/pki/admin.key
```

Instead, we can extract them from kubeconfig.

---

## 5.1 Extract CA Certificate

```bash
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
```

This creates:

```text
ca.crt
```

Purpose:

```text
ca.crt
  ↓
Trust the API Server certificate
```

---

## 5.2 Extract Admin Client Certificate

```bash
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > admin.crt
```

This creates:

```text
admin.crt
```

Purpose:

```text
admin.crt
  ↓
Identifies the client
```

---

## 5.3 Extract Admin Private Key

```bash
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > admin.key
```

This creates:

```text
admin.key
```

Purpose:

```text
admin.key
  ↓
Proves possession of the client's private key
```

---

## 5.4 Protect the Private Key

```bash
chmod 600 admin.key
```

---

## 5.5 Check the Files

```bash
ls -l ca.crt admin.crt admin.key
```

You should now have:

```text
ca.crt
admin.crt
admin.key
```

---

## 5.6 Verify the Client Certificate

```bash
openssl x509 -in admin.crt -noout -subject -issuer
```

This shows:

```text
Subject
   ↓
Client identity

Issuer
   ↓
CA that signed the certificate
```

For a typical kubeadm cluster, the subject may look similar to:

```text
subject=O = system:masters, CN = kubernetes-admin
```

The exact output depends on the cluster configuration.

---

## 5.7 Verify the Private Key

```bash
openssl pkey -in admin.key -noout && echo "Private key OK"
```

Expected:

```text
Private key OK
```

---

# 🔥 Understand the Three Files

This is the most important part of the certificate demonstration.

```text
                 CLIENT
                   │
       ┌───────────┼───────────┐
       │           │           │
       ▼           ▼           ▼
    ca.crt     admin.crt    admin.key
       │           │           │
       │           │           │
       ▼           ▼           ▼
    TRUST       IDENTITY    PROOF OF
    SERVER      CLIENT      POSSESSION
```

### `ca.crt`

```text
ca.crt
  ↓
Used to trust the API Server certificate
```

### `admin.crt`

```text
admin.crt
  ↓
Client certificate
  ↓
Contains client identity
```

### `admin.key`

```text
admin.key
  ↓
Client private key
  ↓
Proves possession of the private key
```

---

# Step 6 — Test curl With Client Certificate

Now test the API Server using the same credentials that `kubectl` uses:

```bash
curl --cacert ./ca.crt --cert ./admin.crt --key ./admin.key https://172.30.1.2:6443/api
```

The flow is:

```text
curl
 │
 ├── ca.crt
 │      ↓
 │   Trust API Server
 │
 ├── admin.crt
 │      ↓
 │   Client identity
 │
 └── admin.key
        ↓
   Prove possession
        │
        ▼
 Kubernetes API Server
```

---

# Step 7 — Test Without CA Verification

For comparison:

```bash
curl -k --cert ./admin.crt --key ./admin.key https://172.30.1.2:6443/api
```

Here:

```text
-k
 ↓
Skip server certificate verification
```

But:

```text
--cert admin.crt
--key admin.key
```

still provide the client certificate credentials.

This is useful to demonstrate the difference between:

```text
TLS server verification
```

and:

```text
Client authentication
```

---

# Important Difference

Do not confuse:

```text
CA certificate
```

with:

```text
Client certificate
```

The correct mental model is:

```text
ca.crt
   ↓
"I trust this CA."
   ↓
Verify API Server certificate


admin.crt
   ↓
"This certificate identifies me."
   ↓
Client identity


admin.key
   ↓
"I possess the private key."
   ↓
Proof of possession
```

Therefore:

```text
CA certificate ≠ User identity
```

---

# Step 8 — Test a Protected API Endpoint

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

---

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

Examples:

```text
Client Certificate
Token
ServiceAccount Token
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

# Step 9 — Compare curl With kubectl

On the control plane:

```bash
kubectl get pods
```

works because `kubectl` uses credentials from kubeconfig.

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

# Step 10 — See kubectl Communicating With API Server

Run:

```bash
kubectl get pods -v=8
```

For even more detailed output:

```bash
kubectl get pods -v=9
```

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

# Step 11 — Check Port 6443 Directly

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

For a quick lab connectivity test:

```bash
curl -k https://172.30.1.2:6443/version
```

For proper certificate verification:

```bash
curl --cacert ./ca.crt https://172.30.1.2:6443/version
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

Then test an unauthenticated protected endpoint:

```bash
curl -k https://172.30.1.2:6443/api/v1/pods
```

---

# Certificate Authentication Demo

On the control plane, extract the credentials:

### 1. Extract CA certificate

```bash
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
```

### 2. Extract admin client certificate

```bash
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > admin.crt
```

### 3. Extract admin private key

```bash
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > admin.key
```

### 4. Protect private key

```bash
chmod 600 admin.key
```

### 5. Check files

```bash
ls -l ca.crt admin.crt admin.key
```

### 6. Verify certificate

```bash
openssl x509 -in admin.crt -noout -subject -issuer
```

### 7. Verify private key

```bash
openssl pkey -in admin.key -noout && echo "Private key OK"
```

### 8. Test authenticated curl

```bash
curl --cacert ./ca.crt --cert ./admin.crt --key ./admin.key https://172.30.1.2:6443/api
```

### 9. Compare with `-k`

```bash
curl -k --cert ./admin.crt --key ./admin.key https://172.30.1.2:6443/api
```

### 10. Check Kubernetes identity

```bash
kubectl auth whoami
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

# Certificate Mental Model

```text
                         Kubernetes API Server
                                  │
                                  │
                         Server Certificate
                                  │
                                  ▲
                                  │
                                CA
                             ca.crt
                                  │
                          establishes trust
                                  │
                                  │
                       ┌──────────┴──────────┐
                       │                     │
                       │                     │
                  admin.crt             admin.key
                       │                     │
                       │                     │
                 Client Identity       Private Key
                       │                     │
                       └──────────┬──────────┘
                                  │
                                  ▼
                       Client Authentication
                                  │
                                  ▼
                           Kubernetes User
                                  │
                                  ▼
                              RBAC
                                  │
                                  ▼
                       Authorization Decision
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

### 5. `ca.crt`

```text
ca.crt
   ↓
Used to establish trust in the API Server certificate
```

### 6. `admin.crt`

```text
admin.crt
   ↓
Client certificate
   ↓
Contains client identity
```

### 7. `admin.key`

```text
admin.key
   ↓
Private key
   ↓
Proves possession of the client credential
```

### 8. Worker reaching API Server ≠ Worker authenticated

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

---

# 🧠 Final Mental Model

```text
                    REQUEST
                       │
                       ▼
                 API Server
                       │
                       ▼
                Can I reach you?
                       │
                       ▼
                  CONNECTIVITY
                       │
                       ▼
                 WHO ARE YOU?
                       │
             ┌─────────┴─────────┐
             │                   │
           TOKEN             CERTIFICATE
             │                   │
             │             admin.crt
             │             admin.key
             │                   │
             └─────────┬─────────┘
                       │
                       ▼
                AUTHENTICATION
                       │
                       ▼
                    IDENTITY
                       │
                       ▼
                AUTHORIZATION
                       │
                       ▼
                     RBAC
                       │
                 ┌─────┴─────┐
                 │           │
               ALLOW        DENY
                 │           │
                 ▼           ▼
              Execute       403
```

---

# ⭐ One-Line Memory Trick

```text
ca.crt      → Trust the server
admin.crt   → Identify the client
admin.key   → Prove possession
Token       → Bearer credential
RBAC        → Permission
```

> **Connectivity tells you that the API Server can be reached. Authentication tells Kubernetes who you are. Authorization/RBAC tells Kubernetes what you are allowed to do.**