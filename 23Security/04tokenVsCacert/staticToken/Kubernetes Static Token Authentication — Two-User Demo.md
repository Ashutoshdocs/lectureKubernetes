# Kubernetes Static Token Authentication — Two-User Demo

## Objective

This demo shows how **static token authentication** works in Kubernetes using two different users:

| User | Token | Namespace | Permission |
|---|---|---|---|
| `alice` | `alice-token-123` | `demo` | Read Pods |
| `bob` | `bob-token-456` | `demo` | Create/Delete Pods |

The demo proves that:

1. Kubernetes API Server can authenticate users using static tokens.
2. The token identifies the user.
3. Authentication and authorization are separate.
4. RBAC determines what each authenticated user can do.
5. Two users can have different permissions even though both authenticate using tokens.
6. A static token is effectively a long-lived credential and has important security limitations.

---

# 1. Architecture

```text
                         Kubernetes Cluster
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│   alice-token-123                    bob-token-456             │
│          │                                  │                  │
│          │ HTTP Authorization              │                  │
│          │ Bearer Token                    │                  │
│          ▼                                  ▼                  │
│                 ┌─────────────────────┐                       │
│                 │   Kubernetes API     │                       │
│                 │      Server         │                       │
│                 └──────────┬──────────┘                       │
│                            │                                   │
│                     Authentication                             │
│                            │                                   │
│                 "Who are you?"                                 │
│                            │                                   │
│              ┌─────────────┴─────────────┐                     │
│              ▼                           ▼                     │
│           alice                         bob                    │
│              │                           │                     │
│              ▼                           ▼                     │
│        RBAC Authorization          RBAC Authorization           │
│              │                           │                     │
│          READ PODS                CREATE/DELETE PODS            │
│              │                           │                     │
└──────────────┼───────────────────────────┼─────────────────────┘
               ▼                           ▼
             demo                        demo
           namespace                   namespace
```

---

# 2. Important Concept

Static token authentication answers:

> **Who is making this request?**

RBAC answers:

> **What is this user allowed to do?**

These are two different steps.

```text
Token
  │
  ▼
Authentication
  │
  │ "This is alice"
  ▼
RBAC
  │
  │ "alice can get/list/watch Pods"
  ▼
Request allowed
```

For Bob:

```text
Token
  │
  ▼
Authentication
  │
  │ "This is bob"
  ▼
RBAC
  │
  │ "bob can create/delete Pods"
  ▼
Request allowed
```

---

# 3. Lab Requirements

This demo assumes a Kubernetes cluster where you have access to the **control-plane node** and can modify the API Server configuration.

Static token authentication is configured through the API Server using:

```text
--token-auth-file
```

This is typically a **self-managed Kubernetes cluster**.

> Managed Kubernetes services may not allow you to configure the API Server this way.

---

# 4. Demo Users

We will create:

```text
User 1:
alice

Token:
alice-token-123
```

and:

```text
User 2:
bob

Token:
bob-token-456
```

We will use the namespace:

```text
demo
```

---

# 5. Create Namespace

Run:

```bash
kubectl create namespace demo
```

Verify:

```bash
kubectl get namespace demo
```

Expected:

```text
NAME    STATUS
demo    Active
```

---

# 6. Create Static Token File

On the control-plane node, create:

```bash
sudo mkdir -p /etc/kubernetes/auth
```

Create the token file:

```bash
sudo vi /etc/kubernetes/auth/tokens.csv
```

Put:

```csv
alice-token-123,alice
bob-token-456,bob
```

The basic format is:

```text
token,user
```

For example:

```text
alice-token-123,alice
```

means:

```text
Token = alice-token-123

User = alice
```

---

# 7. Token File With Groups

For RBAC demonstrations, it is often useful to include groups.

Use:

```csv
alice-token-123,alice,devs
bob-token-456,bob,ops
```

The format becomes:

```text
token,user,uid,"group1,group2"
```

For this demo, we will use:

```csv
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
```

So:

```text
alice-token-123
       │
       ├── username: alice
       ├── UID: alice-id
       └── group: devs
```

and:

```text
bob-token-456
       │
       ├── username: bob
       ├── UID: bob-id
       └── group: ops
```

---

# 8. Secure the Token File

The token file contains credentials.

Protect it:

```bash
sudo chmod 600 /etc/kubernetes/auth/tokens.csv
```

Verify:

```bash
sudo ls -l /etc/kubernetes/auth/tokens.csv
```

You should see permissions similar to:

```text
-rw------- 1 root root ... tokens.csv
```

---

# 9. Configure kube-apiserver

Edit the API Server manifest:

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Find:

```yaml
spec:
  containers:
  - command:
```

Add:

```yaml
- --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

The API Server must also be able to see the file.

Because kubeadm-managed API Server runs as a static Pod, mount the directory.

Add under `volumeMounts`:

```yaml
volumeMounts:
- mountPath: /etc/kubernetes/auth
  name: token-auth
  readOnly: true
```

Then under `volumes`:

```yaml
volumes:
- hostPath:
    path: /etc/kubernetes/auth
    type: DirectoryOrCreate
  name: token-auth
```

The important pieces are:

```yaml
- --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

and:

```yaml
volumeMounts:
- mountPath: /etc/kubernetes/auth
  name: token-auth
  readOnly: true
```

---

# 10. Why the Volume Mount Is Required

The file exists on the control-plane host:

```text
Control Plane Host

/etc/kubernetes/auth/tokens.csv
```

But the API Server runs inside a container:

```text
kube-apiserver container

/etc/kubernetes/auth/tokens.csv
```

The container needs access to the host file.

Therefore:

```text
Host
/etc/kubernetes/auth/tokens.csv
          │
          │ hostPath mount
          ▼
API Server container
/etc/kubernetes/auth/tokens.csv
```

Without the mount, the API Server may fail to start because it cannot read the token file.

---

# 11. Wait for API Server Restart

Because kubeadm uses a static Pod manifest, changing:

```text
/etc/kubernetes/manifests/kube-apiserver.yaml
```

causes kubelet to recreate/restart the API Server.

Check:

```bash
kubectl get pods -n kube-system
```

Look for:

```text
kube-apiserver-<control-plane-node>
```

Check:

```bash
kubectl get pods -n kube-system | grep kube-apiserver
```

---

# 12. Verify API Server Argument

Run:

```bash
kubectl -n kube-system get pod kube-apiserver-$(hostname) \
  -o yaml | grep token-auth-file
```

You should see:

```text
--token-auth-file=/etc/kubernetes/auth/tokens.csv
```

If the Pod name differs, first run:

```bash
kubectl get pods -n kube-system | grep kube-apiserver
```

---

# 13. Create RBAC for Alice

Alice should only be able to:

```text
get Pods
list Pods
watch Pods
```

Create:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: alice-pod-reader
  namespace: demo
rules:
- apiGroups: [""]
  resources:
  - pods
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader-binding
  namespace: demo
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: alice-pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

---

# 14. Create RBAC for Bob

Bob should be able to:

```text
get Pods
list Pods
create Pods
delete Pods
```

Create:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: bob-pod-manager
  namespace: demo
rules:
- apiGroups: [""]
  resources:
  - pods
  verbs:
  - get
  - list
  - create
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bob-pod-manager-binding
  namespace: demo
subjects:
- kind: User
  name: bob
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: bob-pod-manager
  apiGroup: rbac.authorization.k8s.io
EOF
```

---

# 15. Verify RBAC

Check Alice:

```bash
kubectl auth can-i get pods \
  --as=alice \
  -n demo
```

Expected:

```text
yes
```

Check:

```bash
kubectl auth can-i create pods \
  --as=alice \
  -n demo
```

Expected:

```text
no
```

Check Bob:

```bash
kubectl auth can-i create pods \
  --as=bob \
  -n demo
```

Expected:

```text
yes
```

Check:

```bash
kubectl auth can-i delete pods \
  --as=bob \
  -n demo
```

Expected:

```text
yes
```

---

# 16. Create Alice Kubeconfig

We now create a kubeconfig that uses Alice's token.

First determine the API Server address:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

Example:

```text
https://192.168.1.100:6443
```

Determine the CA:

```bash
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
```

Create Alice's kubeconfig:

```bash
kubectl config set-cluster demo-cluster \
  --server=https://<API-SERVER>:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig
```

Add Alice credentials:

```bash
kubectl config set-credentials alice \
  --token=alice-token-123 \
  --kubeconfig=alice.kubeconfig
```

Add context:

```bash
kubectl config set-context alice@demo \
  --cluster=demo-cluster \
  --user=alice \
  --namespace=demo \
  --kubeconfig=alice.kubeconfig
```

Select the context:

```bash
kubectl config use-context alice@demo \
  --kubeconfig=alice.kubeconfig
```

---

# 17. Test Alice

Run:

```bash
kubectl get pods \
  --kubeconfig=alice.kubeconfig \
  -n demo
```

This should work.

Now try:

```bash
kubectl create deployment nginx \
  --image=nginx \
  --kubeconfig=alice.kubeconfig \
  -n demo
```

Expected:

```text
Error from server (Forbidden)
```

Why?

```text
Alice
  │
  │ valid token
  ▼
Authentication
  │
  │ "alice"
  ▼
RBAC
  │
  │ create pods? NO
  ▼
403 Forbidden
```

---

# 18. Create Bob Kubeconfig

Create:

```bash
kubectl config set-cluster demo-cluster \
  --server=https://<API-SERVER>:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=bob.kubeconfig
```

Add credentials:

```bash
kubectl config set-credentials bob \
  --token=bob-token-456 \
  --kubeconfig=bob.kubeconfig
```

Create context:

```bash
kubectl config set-context bob@demo \
  --cluster=demo-cluster \
  --user=bob \
  --namespace=demo \
  --kubeconfig=bob.kubeconfig
```

Use the context:

```bash
kubectl config use-context bob@demo \
  --kubeconfig=bob.kubeconfig
```

---

# 19. Test Bob

Bob can list Pods:

```bash
kubectl get pods \
  --kubeconfig=bob.kubeconfig \
  -n demo
```

Bob can create a deployment:

```bash
kubectl create deployment nginx \
  --image=nginx \
  --kubeconfig=bob.kubeconfig \
  -n demo
```

Check:

```bash
kubectl get pods \
  --kubeconfig=bob.kubeconfig \
  -n demo
```

Bob can delete Pods:

```bash
kubectl delete pod <POD-NAME> \
  --kubeconfig=bob.kubeconfig \
  -n demo
```

---

# 20. Prove Alice and Bob Are Different

Run:

```bash
kubectl auth can-i create pods \
  --as=alice \
  -n demo
```

Result:

```text
no
```

Run:

```bash
kubectl auth can-i create pods \
  --as=bob \
  -n demo
```

Result:

```text
yes
```

The important point is:

```text
              Same API Server
                     │
          ┌──────────┴──────────┐
          │                     │
       Alice                  Bob
          │                     │
   alice-token-123        bob-token-456
          │                     │
          ▼                     ▼
     Authentication       Authentication
          │                     │
       "alice"                "bob"
          │                     │
          ▼                     ▼
        RBAC                  RBAC
          │                     │
       READ                  CREATE
       PODS                  DELETE
```

---

# 21. Test Authentication Directly With curl

We can bypass `kubectl` and directly call the Kubernetes API.

Find the API Server:

```bash
kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}'
```

Example:

```text
https://192.168.1.100:6443
```

Test Alice:

```bash
curl \
  --cacert /etc/kubernetes/pki/ca.crt \
  -H "Authorization: Bearer alice-token-123" \
  https://<API-SERVER>:6443/api
```

If the token is valid, authentication succeeds.

The API Server can identify:

```text
User = alice
```

---

# 22. Test an Authorized Request

Alice:

```bash
curl \
  --cacert /etc/kubernetes/pki/ca.crt \
  -H "Authorization: Bearer alice-token-123" \
  https://<API-SERVER>:6443/api/v1/namespaces/demo/pods
```

The API Server processes:

```text
HTTP Request
     │
     ▼
TLS
     │
     ▼
Authentication
     │
     ▼
Token = alice-token-123
     │
     ▼
User = alice
     │
     ▼
Authorization
     │
     ▼
RoleBinding
     │
     ▼
alice-pod-reader
     │
     ▼
GET pods = ALLOWED
```

---

# 23. Test an Unauthorized Request

Try to create a Pod as Alice using the API.

For example:

```bash
curl \
  --cacert /etc/kubernetes/pki/ca.crt \
  -X POST \
  -H "Authorization: Bearer alice-token-123" \
  -H "Content-Type: application/json" \
  https://<API-SERVER>:6443/api/v1/namespaces/demo/pods
```

The important expected result is:

```text
403 Forbidden
```

Why?

The token is valid.

But:

```text
Authentication = SUCCESS

Authorization = DENIED
```

This is one of the most important Kubernetes security concepts.

---

# 24. Authentication vs Authorization

## Authentication

Authentication asks:

> Who are you?

Static token:

```text
alice-token-123
       │
       ▼
API Server
       │
       ▼
alice
```

---

## Authorization

Authorization asks:

> What can Alice do?

RBAC:

```text
alice
  │
  ▼
RoleBinding
  │
  ▼
alice-pod-reader
  │
  ├── get pods
  ├── list pods
  └── watch pods
```

---

# 25. What Happens With a Wrong Token?

Try:

```bash
kubectl \
  --server=https://<API-SERVER>:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --token=wrong-token \
  get pods -n demo
```

The API Server cannot map the token to a configured user.

Therefore authentication fails.

Conceptually:

```text
wrong-token
     │
     ▼
API Server
     │
     ▼
No matching token
     │
     ▼
Authentication FAILED
     │
     ▼
401 Unauthorized
```

Notice the difference:

```text
401 = authentication problem

403 = authorization problem
```

---

# 26. Very Important Security Warning

Static tokens are simple, but they are **not a preferred authentication mechanism for modern Kubernetes deployments**.

The token is a static credential:

```text
alice-token-123
```

If someone obtains it:

```text
Attacker
   │
   │ steals token
   ▼
alice-token-123
   │
   ▼
API Server
   │
   ▼
alice
```

The attacker can impersonate Alice until the token is removed or changed.

---

# 27. Problems With Static Tokens

### 1. Long-lived credential

The token can remain valid for a long time.

### 2. Rotation is manual

Changing the token requires modifying the token file and managing the API Server configuration.

### 3. Secret leakage risk

Never commit:

```text
tokens.csv
```

to Git.

Never put real production tokens into:

```text
README.md
```

Never share them through:

```text
Slack
Email
Screenshots
GitHub
```

### 4. Difficult auditing

A static token does not inherently provide the same modern identity lifecycle and rotation mechanisms available through stronger authentication systems.

### 5. Poor fit for production

Prefer stronger mechanisms such as:

```text
OIDC
Cloud IAM
Short-lived credentials
Client certificates
Service account tokens
```

depending on the use case.

---

# 28. Demo Security Model

The demo deliberately gives Alice and Bob different permissions.

```text
                    API SERVER
                        │
              ┌─────────┴─────────┐
              │                   │
           Alice                 Bob
              │                   │
      alice-token-123       bob-token-456
              │                   │
              ▼                   ▼
       Authentication       Authentication
              │                   │
              ▼                   ▼
            alice                 bob
              │                   │
              ▼                   ▼
            RBAC                  RBAC
              │                   │
              ▼                   ▼
        Pod Reader          Pod Manager
              │                   │
          GET/LIST          GET/LIST/CREATE/
             /WATCH              DELETE
```

---

# 29. Demonstration Matrix

| Test | Alice | Bob |
|---|---:|---:|
| Authenticate with token | ✅ | ✅ |
| Get Pods | ✅ | ✅ |
| List Pods | ✅ | ✅ |
| Watch Pods | ✅ | ❌ |
| Create Pods | ❌ | ✅ |
| Delete Pods | ❌ | ✅ |
| Delete Namespace | ❌ | ❌ |
| Cluster-wide access | ❌ | ❌ |

The exact result should always be verified with:

```bash
kubectl auth can-i ...
```

because RBAC rules may change during the demo.

---

# 30. Useful Verification Commands

Check Alice:

```bash
kubectl auth can-i --as=alice --list -n demo
```

Check Bob:

```bash
kubectl auth can-i --as=bob --list -n demo
```

Check Alice:

```bash
kubectl auth can-i get pods \
  --as=alice \
  -n demo
```

Check Alice:

```bash
kubectl auth can-i create pods \
  --as=alice \
  -n demo
```

Check Bob:

```bash
kubectl auth can-i create pods \
  --as=bob \
  -n demo
```

Check Bob:

```bash
kubectl auth can-i delete pods \
  --as=bob \
  -n demo
```

---

# 31. Troubleshooting

## API Server does not start

Check:

```bash
kubectl get pods -n kube-system
```

Check API Server logs:

```bash
kubectl logs -n kube-system kube-apiserver-<control-plane-node>
```

Look for errors involving:

```text
token-auth-file
```

or:

```text
tokens.csv
```

---

## Token authentication fails

Verify the file:

```bash
sudo cat /etc/kubernetes/auth/tokens.csv
```

Expected:

```csv
alice-token-123,alice,alice-id,"devs"
bob-token-456,bob,bob-id,"ops"
```

Verify API Server argument:

```bash
kubectl -n kube-system get pod kube-apiserver-<control-plane-node> \
  -o yaml | grep token-auth-file
```

---

## Authentication works but request returns 403

This usually means:

```text
Authentication = SUCCESS
Authorization = FAILED
```

Check:

```bash
kubectl auth can-i get pods \
  --as=alice \
  -n demo
```

Then inspect:

```bash
kubectl get role,rolebinding -n demo
```

---

## Alice unexpectedly has too much access

Check:

```bash
kubectl auth can-i --list \
  --as=alice \
  -n demo
```

Look for:

```text
RoleBindings
ClusterRoleBindings
```

especially:

```bash
kubectl get clusterrolebindings
```

---

# 32. Cleanup

Delete the demo namespace:

```bash
kubectl delete namespace demo
```

Remove the token authentication configuration from:

```text
/etc/kubernetes/manifests/kube-apiserver.yaml
```

Remove:

```yaml
- --token-auth-file=/etc/kubernetes/auth/tokens.csv
```

Remove the volume mount:

```yaml
- mountPath: /etc/kubernetes/auth
  name: token-auth
  readOnly: true
```

Remove the volume:

```yaml
- hostPath:
    path: /etc/kubernetes/auth
    type: DirectoryOrCreate
  name: token-auth
```

Then remove the credentials:

```bash
sudo rm -rf /etc/kubernetes/auth
```

Remove the demo kubeconfigs:

```bash
rm -f alice.kubeconfig
rm -f bob.kubeconfig
```

---

# 33. Final Workflow

The complete authentication flow is:

```text
              USER
                │
                │
                │ Bearer Token
                ▼
        ┌─────────────────┐
        │  Kubernetes     │
        │  API Server     │
        └────────┬────────┘
                 │
                 ▼
          Authentication
                 │
        ┌────────┴────────┐
        │                 │
 alice-token-123     bob-token-456
        │                 │
        ▼                 ▼
      alice              bob
        │                 │
        └────────┬────────┘
                 ▼
             RBAC
                 │
                 ▼
          Authorization
                 │
          ┌──────┴──────┐
          │             │
        ALLOW          DENY
          │             │
          ▼             ▼
       Execute       403 Forbidden
       Request
```

---

# 34. Key Takeaways

### Authentication

```text
Static Token
     ↓
API Server
     ↓
Who is this?
     ↓
alice / bob
```

### Authorization

```text
alice / bob
     ↓
RBAC
     ↓
What can they do?
     ↓
ALLOW / DENY
```

### The most important distinction

```text
VALID TOKEN ≠ FULL ACCESS
```

A valid token only proves the configured identity.

RBAC still decides what that identity can do.

Therefore:

```text
Authentication
      +
Authorization
      =
Secure API Access
```

---

# 35. Production Recommendation

Use this static-token demo for **learning and understanding Kubernetes authentication**.

For production, prefer an authentication mechanism that supports appropriate identity lifecycle, rotation, and centralized management, such as:

```text
OIDC
Cloud IAM
Client certificates
Short-lived tokens
Service account tokens
```

and always apply:

```text
Least Privilege
     +
RBAC
     +
Credential Rotation
     +
Secret Protection
     +
Audit Logging
```

---

## Lab Goal

At the end of this exercise, you should be able to explain:

> **How Kubernetes takes a static bearer token, maps it to a username, authenticates the request, passes that identity to the authorization layer, evaluates RBAC, and finally either allows the request or returns 403 Forbidden.**