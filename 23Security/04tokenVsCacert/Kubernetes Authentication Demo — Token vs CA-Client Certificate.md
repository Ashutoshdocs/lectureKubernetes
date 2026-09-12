# Kubernetes Authentication Demo  
## Token vs CA / Client Certificate Authentication

---

## 🎯 Objective

This demo teaches the difference between:

- **Token-based authentication**
- **Client certificate-based authentication**
- **CA certificate and its purpose**
- **Authentication vs Authorization**
- **RBAC after authentication**

By the end of this demo, you should understand exactly what happens when `kubectl` communicates with the Kubernetes API Server.

---

# 1. Authentication vs Authorization

Before comparing tokens and certificates, understand the two stages.

### Authentication

Authentication answers:

```text
WHO ARE YOU?
```

For example:

```text
alice
```

or:

```text
system:serviceaccount:auth-demo:token-user
```

### Authorization

Authorization answers:

```text
WHAT ARE YOU ALLOWED TO DO?
```

For example:

```text
get pods          ✅
list pods         ✅
create deployment ❌
```

The overall process is:

```text
kubectl
   |
   v
API Server
   |
   v
Authentication
   |
   | "Who are you?"
   v
Identity
   |
   v
Authorization / RBAC
   |
   | "What can you do?"
   v
Allowed / Denied
```

---

# 2. Token vs Certificate Authentication

Kubernetes can authenticate clients using different mechanisms.

This demo focuses on:

```text
                 Authentication
                       |
             +---------+---------+
             |                   |
             v                   v
       Token-based       Certificate-based
       Authentication    Authentication
             |                   |
             v                   v
        Bearer Token      Client Certificate
                          + Private Key
```

---

# 3. Important CA Concept

One of the most common mistakes is thinking:

```text
CA certificate = user credential
```

That is incorrect.

There are three different concepts:

| File | Purpose |
|---|---|
| `ca.crt` | Establishes trust in certificates signed by the CA |
| `client.crt` | Identifies the client |
| `client.key` | Proves possession of the client's private key |

Think of it as:

```text
CA
 |
 | signs
 v
Client Certificate
 |
 | identifies
 v
alice

Private Key
 |
 | proves possession
 v
alice can authenticate
```

---

# 4. Token Authentication

A token is presented to the API Server as a bearer credential.

Conceptually:

```text
kubectl
   |
   | Authorization: Bearer <TOKEN>
   |
   v
API Server
   |
   v
Token authentication
   |
   v
Identity
```

A common Kubernetes example is a **ServiceAccount token**.

Example identity:

```text
system:serviceaccount:auth-demo:token-user
```

---

# 5. Certificate Authentication

Certificate authentication uses:

```text
client.crt
+
client.key
```

The certificate contains the client's identity.

For example:

```text
CN=alice
O=developers
```

The API Server verifies the certificate against a trusted CA.

Conceptually:

```text
kubectl
   |
   | client.crt
   | client.key
   |
   v
API Server
   |
   v
Certificate verification
   |
   v
Identity:
alice
```

---

# 6. Architecture of This Demo

We will create two different identities:

```text
                         Kubernetes
                         API Server
                              |
                +-------------+-------------+
                |                           |
                v                           v
           Token User                    Alice
                |                           |
                v                           v
          ServiceAccount              Client Certificate
          Token                       + Private Key
                |                           |
                +-------------+-------------+
                              |
                              v
                           RBAC
```

The important point is:

> Both identities can be authenticated and both can be authorized using RBAC.

The authentication mechanism is different.

---

# 7. Prerequisites

You need:

- A working Kubernetes cluster
- `kubectl`
- Cluster administrator access for the certificate portion
- `openssl`

Check:

```bash
kubectl version
```

Check cluster connectivity:

```bash
kubectl cluster-info
```

Check the current context:

```bash
kubectl config current-context
```

---

# 8. Create Demo Namespace

Create a namespace:

```bash
kubectl create namespace auth-demo
```

Verify:

```bash
kubectl get namespace auth-demo
```

---

# 9. PART A — Token Authentication

## Step 1 — Create ServiceAccount

Create a ServiceAccount:

```bash
kubectl create serviceaccount token-user \
  -n auth-demo
```

Verify:

```bash
kubectl get serviceaccount token-user \
  -n auth-demo
```

---

# 10. Generate a ServiceAccount Token

Modern Kubernetes versions generally use short-lived, bound ServiceAccount tokens.

Generate one using:

```bash
TOKEN=$(kubectl create token token-user \
  -n auth-demo)
```

Display it for demonstration:

```bash
echo "$TOKEN"
```

> ⚠️ Treat the token as a credential. Do not expose real production tokens.

---

# 11. Test Token Authentication

Use the token directly:

```bash
kubectl --token="$TOKEN" \
  auth whoami
```

Expected identity:

```text
system:serviceaccount:auth-demo:token-user
```

This proves:

```text
TOKEN
  |
  v
API Server
  |
  v
Authentication successful
  |
  v
Identity:
system:serviceaccount:auth-demo:token-user
```

---

# 12. Test Authorization

Now try:

```bash
kubectl --token="$TOKEN" \
  get pods \
  -n auth-demo
```

Depending on the cluster configuration, you may receive:

```text
Error from server (Forbidden)
```

This is an important teaching point.

Authentication may have succeeded:

```text
WHO ARE YOU?

Authenticated
```

but authorization failed:

```text
WHAT CAN YOU DO?

Not allowed
```

---

# 13. Create a Role

Create a file:

```text
role.yaml
```

Contents:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: auth-demo
rules:
- apiGroups: [""]
  resources:
  - pods
  verbs:
  - get
  - list
  - watch
```

Apply it:

```bash
kubectl apply -f role.yaml
```

Verify:

```bash
kubectl get role \
  -n auth-demo
```

---

# 14. Create RoleBinding for Token User

Create:

```text
rolebinding.yaml
```

Contents:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: token-user-binding
  namespace: auth-demo
subjects:
- kind: ServiceAccount
  name: token-user
  namespace: auth-demo
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Apply:

```bash
kubectl apply -f rolebinding.yaml
```

---

# 15. Test Token User Again

Generate a token:

```bash
TOKEN=$(kubectl create token token-user \
  -n auth-demo)
```

Test:

```bash
kubectl --token="$TOKEN" \
  get pods \
  -n auth-demo
```

The ServiceAccount is now authorized to:

```text
get pods
list pods
watch pods
```

---

# 16. Prove Least Privilege

Try creating a Deployment:

```bash
kubectl --token="$TOKEN" \
  create deployment nginx \
  --image=nginx \
  -n auth-demo
```

This should fail because our Role does not allow:

```text
create deployments
```

Check explicitly:

```bash
kubectl auth can-i \
  create deployments \
  --as=system:serviceaccount:auth-demo:token-user \
  -n auth-demo
```

Expected:

```text
no
```

Check pod access:

```bash
kubectl auth can-i \
  get pods \
  --as=system:serviceaccount:auth-demo:token-user \
  -n auth-demo
```

Expected:

```text
yes
```

---

# 17. What Did We Prove?

The token authenticated:

```text
system:serviceaccount:auth-demo:token-user
```

Then RBAC determined what it could do.

```text
                    TOKEN
                      |
                      v
                Authentication
                      |
                      v
       system:serviceaccount:auth-demo:token-user
                      |
                      v
                    RBAC
                      |
          +-----------+-----------+
          |                       |
      get pods               create deployment
          |                       |
          v                       v
        ALLOW                    DENY
```

---

# 18. PART B — Client Certificate Authentication

Now create a certificate-based identity:

```text
alice
```

We will create:

```text
alice.key
alice.csr
alice.crt
```

---

# 19. Generate Alice's Private Key

Run:

```bash
openssl genrsa \
  -out alice.key \
  2048
```

This creates:

```text
alice.key
```

This is the **private key**.

Keep it secret.

---

# 20. Generate Certificate Signing Request

Run:

```bash
openssl req -new \
  -key alice.key \
  -out alice.csr \
  -subj "/CN=alice/O=developers"
```

The certificate identity is:

```text
CN=alice
O=developers
```

Conceptually:

```text
CN
 |
 +---- Username

O
 |
 +---- Group
```

The exact interpretation depends on the Kubernetes API Server certificate-authentication configuration.

---

# 21. Sign Alice's Certificate

In a controlled kubeadm-style lab, an administrator can sign the certificate using the cluster CA.

Example:

```bash
openssl x509 -req \
  -in alice.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out alice.crt \
  -days 365 \
  -sha256
```

This creates:

```text
alice.crt
```

Now we have:

```text
alice.key
alice.crt
```

---

# ⚠️ SECURITY WARNING

This file is extremely sensitive:

```text
/etc/kubernetes/pki/ca.key
```

It is the CA private key.

Do not give it to normal users.

Do not copy it outside the control plane unnecessarily.

The above command is intended only for a controlled teaching/lab environment.

In production, certificate issuance should be handled through an appropriate administrative or certificate-signing workflow.

---

# 22. Inspect Alice's Certificate

Run:

```bash
openssl x509 \
  -in alice.crt \
  -noout \
  -subject \
  -issuer
```

You should see information corresponding to:

```text
CN=alice
O=developers
```

The issuer should correspond to the CA that signed the certificate.

---

# 23. Configure Alice in kubeconfig

Add Alice as a kubeconfig user:

```bash
kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key
```

Notice:

```text
--client-certificate
--client-key
```

There is no token.

---

# 24. Create Alice's Context

First find the cluster name:

```bash
kubectl config get-clusters
```

Assume the cluster is:

```text
kubernetes
```

Create the context:

```bash
kubectl config set-context alice-context \
  --cluster=kubernetes \
  --user=alice \
  --namespace=auth-demo
```

Switch to Alice:

```bash
kubectl config use-context alice-context
```

---

# 25. Test Certificate Authentication

Run:

```bash
kubectl auth whoami
```

Expected:

```text
alice
```

Depending on configuration, groups may also be shown:

```text
developers
```

This demonstrates:

```text
alice.crt
    +
alice.key
    |
    v
API Server
    |
    v
Certificate authentication
    |
    v
alice
```

---

# 26. Test Alice's Authorization

Run:

```bash
kubectl get pods \
  -n auth-demo
```

If Alice has not been granted an RBAC RoleBinding yet, the request should be denied.

This is intentional.

It proves:

```text
Certificate authentication
        |
        v
Authentication successful
        |
        v
Authorization
        |
        v
No permission
```

---

# 27. Bind the Role to Alice

Create:

```text
alice-rolebinding.yaml
```

Contents:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: auth-demo
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Apply:

```bash
kubectl apply \
  -f alice-rolebinding.yaml
```

---

# 28. Test Alice Again

Run:

```bash
kubectl get pods \
  -n auth-demo
```

Alice should now be able to read Pods.

Check:

```bash
kubectl auth can-i \
  get pods \
  -n auth-demo
```

Expected:

```text
yes
```

Try:

```bash
kubectl auth can-i \
  create deployments \
  -n auth-demo
```

Expected:

```text
no
```

---

# 29. Side-by-Side Comparison

We now have two identities.

### Token User

```text
Identity:
system:serviceaccount:auth-demo:token-user

Credential:
Bearer Token
```

### Certificate User

```text
Identity:
alice

Credential:
Client Certificate + Private Key
```

Both are processed by:

```text
Authentication
      |
      v
Identity
      |
      v
Authorization
      |
      v
RBAC
```

---

# 30. Token vs Client Certificate

| Feature | Token | Client Certificate |
|---|---|---|
| Credential | Bearer token | Certificate + private key |
| Example | ServiceAccount token | `alice.crt` + `alice.key` |
| Identity | Associated with token | Certificate identity |
| Private key | Not required | Required |
| CA | Depends on token mechanism | Used for certificate trust |
| Typical use | Workloads / ServiceAccounts | Human or client identities |
| RBAC | Yes | Yes |
| Authentication | Yes | Yes |
| Authorization | Separate | Separate |

---

# 31. CA Certificate vs Client Certificate

This distinction is extremely important.

## CA Certificate

```text
ca.crt
```

Purpose:

```text
Establish trust
```

Think:

```text
"I trust certificates issued by this CA."
```

---

## Client Certificate

```text
client.crt
```

Purpose:

```text
Identify the client
```

Example:

```text
CN=alice
```

---

## Client Private Key

```text
client.key
```

Purpose:

```text
Prove possession of the private key
```

---

# 32. Kubeconfig Comparison

### Token User

```yaml
users:
- name: token-user
  user:
    token: <TOKEN>
```

The user has:

```text
TOKEN
```

---

### Certificate User

```yaml
users:
- name: alice
  user:
    client-certificate-data: <CLIENT_CERTIFICATE>
    client-key-data: <PRIVATE_KEY>
```

The user has:

```text
CLIENT CERTIFICATE
+
PRIVATE KEY
```

---

### Cluster CA

The cluster entry can contain:

```yaml
clusters:
- name: kubernetes
  cluster:
    server: https://API_SERVER:6443
    certificate-authority-data: <CA_CERTIFICATE>
```

This is primarily about trusting the API Server's TLS certificate.

It does **not** mean:

```text
CA certificate = Alice's credential
```

---

# 33. Complete kubectl Request Flow

## Token Authentication

```text
                         kubectl
                            |
                            |
                     Bearer Token
                            |
                            v
                    Kubernetes API Server
                            |
                            v
                   Token Authentication
                            |
                            v
                         Identity
                            |
                            v
                           RBAC
                            |
                  +---------+---------+
                  |                   |
                ALLOW                DENY
                  |                   |
                  v                   v
              Execute                403
```

---

## Certificate Authentication

```text
                         kubectl
                            |
                  Client Certificate
                         +
                    Private Key
                            |
                            v
                    Kubernetes API Server
                            |
                            v
                Certificate Authentication
                            |
                            v
                         Identity
                            |
                            v
                           RBAC
                            |
                  +---------+---------+
                  |                   |
                ALLOW                DENY
                  |                   |
                  v                   v
              Execute                403
```

---

# 34. The Most Important Mental Model

Remember:

```text
                 CREDENTIAL
                     |
          +----------+----------+
          |                     |
        TOKEN              CERTIFICATE
          |                     |
          |              client.crt
          |              client.key
          |                     |
          +----------+----------+
                     |
                     v
              AUTHENTICATION
                     |
                     v
                  WHO?
                     |
                     v
                IDENTITY
                     |
                     v
              AUTHORIZATION
                     |
                     v
                   RBAC
                     |
                     v
            WHAT CAN I DO?
```

---

# 35. Easy Analogy

Imagine entering a secure office.

### Token

A token is like an access pass:

```text
ACCESS PASS
     |
     v
Bearer credential
```

Whoever possesses a valid pass can present it.

---

### Client Certificate

A client certificate is like an ID card:

```text
ID CARD
  |
  v
Alice
```

The private key provides proof that the client possesses the corresponding private credential.

---

### CA

The CA is the trusted authority:

```text
Trusted Authority
       |
       v
"I recognize this certificate issuer."
```

---

### RBAC

The security guard checks:

```text
What is Alice allowed to enter?
```

That is authorization.

---

# 36. Authentication Failure vs Authorization Failure

These are not the same.

## Authentication Failure

The API Server cannot establish who you are.

Examples include:

```text
Invalid token
Invalid certificate
Untrusted certificate
Invalid credentials
```

Conceptually:

```text
WHO ARE YOU?
     |
     v
Could not authenticate
```

---

## Authorization Failure

Kubernetes knows who you are but denies the requested operation.

Example:

```text
alice
 |
 v
Authenticated
 |
 v
RBAC
 |
 v
Cannot create deployments
```

Typical result:

```text
403 Forbidden
```

Remember:

```text
Authentication = WHO?
Authorization = WHAT?
```

---

# 37. Useful Debugging Commands

Check current context:

```bash
kubectl config current-context
```

List contexts:

```bash
kubectl config get-contexts
```

List configured users:

```bash
kubectl config get-users
```

Check authenticated identity:

```bash
kubectl auth whoami
```

Check a permission:

```bash
kubectl auth can-i get pods \
  -n auth-demo
```

Check ServiceAccount permission:

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:auth-demo:token-user \
  -n auth-demo
```

Check whether Alice can create deployments:

```bash
kubectl auth can-i create deployments \
  --as=alice \
  -n auth-demo
```

---

# 38. Inspect kubeconfig

Run:

```bash
kubectl config view
```

For a complete view including sensitive data:

```bash
kubectl config view --raw
```

> ⚠️ Be careful with `--raw`. It can expose tokens, private keys, and certificate data. Do not paste the output into public locations.

Look for:

```yaml
users:
```

You may see:

```yaml
- name: token-user
  user:
    token: ...

- name: alice
  user:
    client-certificate-data: ...
    client-key-data: ...
```

---

# 39. Important Security Lessons

### Token

Protect:

```text
TOKEN
```

because it is a bearer credential.

---

### Private Key

Protect:

```text
alice.key
```

because possession of the private key is critical to certificate authentication.

---

### CA Private Key

Protect extremely carefully:

```text
ca.key
```

Compromise of the CA private key can have major consequences because it can allow unauthorized certificates to be issued.

---

# 40. Common Mistakes

## ❌ Mistake 1

```text
ca.crt authenticates Alice
```

### Correct

```text
client.crt
    ↓
contains client identity

client.key
    ↓
proves private-key possession

ca.crt
    ↓
establishes trust
```

---

## ❌ Mistake 2

```text
Authentication means permission
```

### Correct

```text
Authentication
    ↓
Who are you?

Authorization
    ↓
What can you do?
```

---

## ❌ Mistake 3

```text
Valid token = administrator
```

### Correct

```text
Valid token
    ↓
Authenticated identity
    ↓
RBAC determines permissions
```

---

## ❌ Mistake 4

```text
Valid certificate = cluster-admin
```

### Correct

```text
Valid certificate
    ↓
Authenticated identity
    ↓
RBAC
    ↓
Permissions
```

---

# 41. Final Demo Flow

Run the demonstration in this order:

```text
1. Create auth-demo namespace
             ↓
2. Create token-user ServiceAccount
             ↓
3. Generate ServiceAccount token
             ↓
4. Authenticate using token
             ↓
5. Show identity
             ↓
6. Show authorization failure
             ↓
7. Create pod-reader Role
             ↓
8. Bind Role to token-user
             ↓
9. Show authorization success
             ↓
10. Create Alice private key
             ↓
11. Create Alice CSR
             ↓
12. Sign Alice certificate
             ↓
13. Configure Alice in kubeconfig
             ↓
14. Authenticate using certificate
             ↓
15. Show Alice identity
             ↓
16. Show authorization failure
             ↓
17. Bind Role to Alice
             ↓
18. Show authorization success
             ↓
19. Compare token vs certificate
```

---

# 42. Final Takeaway

The single most important thing to remember:

```text
TOKEN
  |
  v
"I have this bearer credential."
```

```text
CLIENT CERTIFICATE + PRIVATE KEY
  |
  v
"I have a certificate identifying me
 and I can prove possession of its private key."
```

```text
CA CERTIFICATE
  |
  v
"I trust certificates issued by this CA."
```

And finally:

```text
AUTHENTICATION
       |
       v
    WHO ARE YOU?
       |
       v
    IDENTITY
       |
       v
AUTHORIZATION / RBAC
       |
       v
WHAT CAN YOU DO?
```

---

# 🧠 One-Line Memory Trick

```text
Token       → Credential
Client Cert → Identity
Private Key → Proof of possession
CA Cert     → Trust
RBAC        → Permission
```

---

# 🎓 Questions for Students

After completing this demo, you should be able to answer:

1. What is authentication?
2. What is authorization?
3. What is a ServiceAccount?
4. What is a ServiceAccount token?
5. What is a client certificate?
6. What does `client.key` do?
7. What does `ca.crt` do?
8. Is `ca.crt` itself a user's authentication credential?
9. Where does the username `alice` come from?
10. Why can an authenticated user receive `403 Forbidden`?
11. What is the difference between `client.crt` and `ca.crt`?
12. Why must bearer tokens be protected?
13. Why must private keys be protected?
14. Can both token and certificate identities use RBAC?
15. What is the difference between authentication failure and authorization failure?

---

# 🏁 Final Summary

```text
                         Kubernetes API Server
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
           TOKEN AUTH                         CERT AUTH
                 |                                 |
          Bearer Token                    Client Cert + Key
                 |                                 |
                 +----------------+----------------+
                                  |
                                  v
                           AUTHENTICATION
                                  |
                                  v
                               IDENTITY
                                  |
                                  v
                            AUTHORIZATION
                                  |
                                  v
                                 RBAC
                                  |
                    +-------------+-------------+
                    |                           |
                  ALLOW                       DENY
                    |                           |
                    v                           v
                API action                  403 Forbidden
```

> **Token vs Certificate is primarily a difference in how the client proves its identity. RBAC remains the mechanism that determines what that authenticated identity is allowed to do.**