# Kubernetes ServiceAccount Security Demo

> **Purpose:** Prove, with a safe hands-on lab, why Kubernetes workloads should use **dedicated ServiceAccounts with least-privilege RBAC** — and demonstrate the security flaw that appears when multiple applications share an over-privileged ServiceAccount.

---

# 1. What exactly are we proving?

The important security question is not:

> "Does my Pod have a ServiceAccount?"

A Pod normally has a ServiceAccount identity. If `serviceAccountName` is omitted, Kubernetes normally assigns the namespace's `default` ServiceAccount.

The real question is:

> **What permissions does the ServiceAccount have, and how many workloads share it?**

This demo deliberately creates a **bad design**, demonstrates its blast radius, removes it, and then builds the **secure design**.

## We will prove four things

### Proof 1 — A Pod gets an identity

```text
Pod
 |
 +--> ServiceAccount
```

### Proof 2 — RBAC controls what that identity can do

```text
ServiceAccount
      |
      v
RoleBinding
      |
      v
Role
      |
      v
Allowed API operations
```

### Proof 3 — Shared ServiceAccount = shared permissions

```text
                    BAD DESIGN

       Application A             Application B
             |                         |
             +-----------+-------------+
                         |
                  SAME ServiceAccount
                         |
                         v
                    Broad RBAC
                         |
          +--------------+--------------+
          |              |              |
       read Pods      read Secrets   delete Pods
```

If Application A is compromised, the attacker operates with the **same Kubernetes identity** available to Application B.

### Proof 4 — Dedicated ServiceAccounts reduce blast radius

```text
                    GOOD DESIGN

       Application A             Application B
             |                         |
            SA-A                      SA-B
             |                         |
          Role-A                    Role-B
             |                         |
        get/list Pods           get ConfigMaps
             |                         |
             X                         X
        read Secrets             delete Pods
```

Compromising Application A does **not automatically give it Application B's RBAC permissions**.

---

# 2. Security concept: identity vs permission

Kubernetes separates two ideas.

```text
                  Kubernetes API Server
                           |
              +------------+------------+
              |                         |
      AUTHENTICATION              AUTHORIZATION
              |                         |
       "Who are you?"            "What can you do?"
              |                         |
       ServiceAccount                    RBAC
              |                    Role / ClusterRole
              |                  RoleBinding / CRB
              +------------+------------+
                           |
                     ALLOW / DENY
```

## Authentication

The API server identifies the caller.

Example:

```text
system:serviceaccount:sa-demo:app-a
```

## Authorization

RBAC decides whether that identity can perform an operation.

Example:

```text
get pods
```

may be:

```text
ALLOW
```

while:

```text
get secrets
```

may be:

```text
DENY
```

A valid ServiceAccount token does **not** mean the workload is allowed to do everything.

---

# 3. Why ServiceAccounts matter

A ServiceAccount is a Kubernetes identity intended for workloads.

Instead of giving an application:

```text
administrator credentials
```

we can give it:

```text
app-reader
```

and then define exactly what `app-reader` may do.

For example:

```yaml
rules:
  - apiGroups: [""]
    resources:
      - pods
    verbs:
      - get
      - list
      - watch
```

That means:

```text
app-reader
    |
    +-- get pods       YES
    +-- list pods      YES
    +-- watch pods     YES
    +-- delete pods    NO
    +-- get secrets    NO
    +-- create pods    NO
```

This is **least privilege**.

---

# 4. Lab architecture

We will use one namespace:

```text
sa-demo
```

and create two fictional applications:

```text
app-a
app-b
```

## Phase 1 — Bad design

Both applications share:

```text
shared-app
```

and `shared-app` receives broad permissions.

```text
             app-a Pod
                 |
                 |
                 v
            shared-app SA
                 ^
                 |
                 |
             app-b Pod

                 |
                 v
            Broad Role
                 |
        +--------+---------+
        |        |         |
       Pods    Secrets   ConfigMaps
```

We then simulate:

```text
Attacker compromises app-a
             |
             v
Attacker can use app-a's SA identity
             |
             v
shared-app
             |
             v
Broad permissions
```

Because `app-b` also uses the same identity, the permissions are shared.

---

# 5. Phase 2 — Secure design

We replace the shared identity with:

```text
app-a  --> app-a-sa --> Role-A
app-b  --> app-b-sa --> Role-B
```

Example:

```text
app-a-sa
   |
   +-- get/list/watch pods
   |
   X-- get secrets

app-b-sa
   |
   +-- get/list configmaps
   |
   X-- delete pods
```

Now compromise of `app-a` does not automatically grant `app-b`'s permissions.

---

# 6. Safety warning

This is a **local/demo cluster exercise**.

Do not use real production secrets.

We will create a fake Kubernetes Secret containing:

```text
demo-password=not-a-real-password
```

The purpose is to demonstrate the **impact of excessive RBAC**, not to access real credentials.

Also:

> **Never put a production administrator kubeconfig into a demo container.**

---

# 7. Prerequisites

Check the cluster:

```bash
kubectl get nodes
```

Check your permissions:

```bash
kubectl auth can-i --list
```

You need enough privileges to create:

- Namespace
- ServiceAccount
- Role
- RoleBinding
- Pods
- Secret

---

# 8. Create the demo namespace

```bash
kubectl create namespace sa-demo
```

Verify:

```bash
kubectl get namespace sa-demo
```

---

# 9. Part A — What happens when we do not specify a ServiceAccount?

Create:

## `01-default-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: default-sa-pod
  namespace: sa-demo
spec:
  containers:
    - name: app
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          echo "Default ServiceAccount demo"
          sleep 3600
```

Apply:

```bash
kubectl apply -f 01-default-pod.yaml
```

Check:

```bash
kubectl get pod default-sa-pod -n sa-demo \
  -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

Expected:

```text
default
```

## Important lesson

We did not write:

```yaml
serviceAccountName: default
```

but Kubernetes assigned:

```text
default
```

Therefore:

> **"I did not specify a ServiceAccount" does not mean "my Pod has no ServiceAccount."**

It normally means:

```text
Pod
 |
 v
namespace/default ServiceAccount
```

---

# 10. Why the `default` ServiceAccount can become a problem

The default ServiceAccount is not automatically `cluster-admin`.

The problem occurs when an administrator gives it excessive permissions.

For example, in a badly configured cluster someone might do:

```bash
kubectl create clusterrolebinding dangerous-default-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=sa-demo:default
```

Now check:

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:sa-demo:default \
  --all-namespaces
```

Expected:

```text
yes
```

And:

```bash
kubectl auth can-i create deployments \
  --as=system:serviceaccount:sa-demo:default \
  --all-namespaces
```

Expected:

```text
yes
```

This is an intentionally bad configuration.

---

# 11. The important security demonstration

The key question is:

> **What happens if an attacker compromises a Pod using that ServiceAccount?**

The attacker does not need to magically become Kubernetes admin.

If the Pod already has access to a powerful ServiceAccount identity, the attacker can potentially make Kubernetes API requests using that identity.

Conceptually:

```text
                 Attacker
                    |
                    v
             Compromised Pod
                    |
                    v
           Pod's ServiceAccount
                    |
                    v
               Kubernetes API
                    |
                    v
                  RBAC
                    |
             +------+------+
             |             |
          ALLOWED         DENIED
```

If the ServiceAccount has excessive permissions:

```text
Compromised Pod
      |
      v
Powerful ServiceAccount
      |
      +---- read Secrets
      +---- create Pods
      +---- delete Pods
      +---- modify workloads
      +---- potentially modify RBAC
```

That is the **blast radius**.

---

# 12. Safe blast-radius demo — shared ServiceAccount

Now we will create a realistic example with two applications.

```text
Application A
Application B
      |
      v
 shared-app ServiceAccount
      |
      v
 broad Role
```

The important point is:

> **Both applications have the same Kubernetes identity.**

---

# 13. Create the intentionally over-privileged ServiceAccount

Create:

## `02-shared-serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: shared-app
  namespace: sa-demo
```

Apply:

```bash
kubectl apply -f 02-shared-serviceaccount.yaml
```

Verify:

```bash
kubectl get serviceaccount shared-app -n sa-demo
```

---

# 14. Create a harmless demo Secret

Create:

## `03-demo-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
  namespace: sa-demo
type: Opaque
stringData:
  username: demo-user
  password: not-a-real-password
```

Apply:

```bash
kubectl apply -f 03-demo-secret.yaml
```

Verify:

```bash
kubectl get secret demo-secret -n sa-demo
```

This is **not a real credential**.

---

# 15. Give the shared ServiceAccount excessive permissions

Create:

## `04-shared-role.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: shared-app-role
  namespace: sa-demo
rules:
  - apiGroups: [""]
    resources:
      - pods
      - secrets
      - configmaps
    verbs:
      - get
      - list
      - watch
      - create
      - delete
```

This is deliberately broader than the application actually needs.

Apply:

```bash
kubectl apply -f 04-shared-role.yaml
```

---

# 16. Bind the broad Role to the shared ServiceAccount

Create:

## `05-shared-rolebinding.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: shared-app-binding
  namespace: sa-demo
subjects:
  - kind: ServiceAccount
    name: shared-app
    namespace: sa-demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: shared-app-role
```

Apply:

```bash
kubectl apply -f 05-shared-rolebinding.yaml
```

---

# 17. Verify the blast radius BEFORE creating any Pods

Ask Kubernetes what the shared identity can do.

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:sa-demo:shared-app
```

Now test specific operations.

## Read Pods

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:sa-demo:shared-app
```

Expected:

```text
yes
```

## Read Secrets

```bash
kubectl auth can-i get secrets \
  --as=system:serviceaccount:sa-demo:shared-app
```

Expected:

```text
yes
```

## Delete Pods

```bash
kubectl auth can-i delete pods \
  --as=system:serviceaccount:sa-demo:shared-app
```

Expected:

```text
yes
```

## Create Pods

```bash
kubectl auth can-i create pods \
  --as=system:serviceaccount:sa-demo:shared-app
```

Expected:

```text
yes
```

This is already a security finding:

```text
Application needs:
    read Pods

Actual permissions:
    read Pods
    read Secrets
    create Pods
    delete Pods
    ...
```

---

# 18. Create Application A and Application B

Create:

## `06-two-apps-shared-sa.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-a
  namespace: sa-demo
  labels:
    app: app-a
spec:
  serviceAccountName: shared-app
  containers:
    - name: app
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          echo "Application A"
          sleep 3600

---
apiVersion: v1
kind: Pod
metadata:
  name: app-b
  namespace: sa-demo
  labels:
    app: app-b
spec:
  serviceAccountName: shared-app
  containers:
    - name: app
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          echo "Application B"
          sleep 3600
```

Apply:

```bash
kubectl apply -f 06-two-apps-shared-sa.yaml
```

Verify:

```bash
kubectl get pods -n sa-demo
```

---

# 19. PROOF — both Pods use the SAME identity

Run:

```bash
kubectl get pods -n sa-demo \
  -o custom-columns=NAME:.metadata.name,SERVICEACCOUNT:.spec.serviceAccountName
```

You should see:

```text
NAME              SERVICEACCOUNT
app-a             shared-app
app-b             shared-app
default-sa-pod    default
```

This is the critical observation:

```text
app-a
  |
  +---- shared-app
             ^
             |
app-b
```

Both applications share the same Kubernetes identity.

---

# 20. PROOF — Application A's identity can read the Secret

First prove the identity is allowed:

```bash
kubectl auth can-i get secret/demo-secret \
  --as=system:serviceaccount:sa-demo:shared-app
```

Expected:

```text
yes
```

Now simulate the API request **from inside app-a**.

The Pod has a ServiceAccount token mounted for its workload identity.

Run:

```bash
kubectl exec -n sa-demo app-a -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

  curl -sS --cacert "$CACERT" \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/sa-demo/secrets/demo-secret
'
```

You should receive the Secret object.

You may see a response containing something similar to:

```json
{
  "kind": "Secret",
  "metadata": {
    "name": "demo-secret"
  }
}
```

The exact JSON contains Kubernetes metadata and the Secret data.

---

# 21. Why this proves the security flaw

Imagine:

```text
app-a = payment application
app-b = reporting application
```

Suppose the reporting application needs:

```text
get configmaps
```

but both applications share:

```text
shared-app
```

and that identity can:

```text
get secrets
create pods
delete pods
```

If an attacker compromises `app-a`:

```text
                 Attacker
                    |
                    v
                app-a Pod
                    |
                    v
              shared-app SA
                    |
                    v
               Broad Role
                    |
          +---------+---------+
          |         |         |
        Secrets    Pods    ConfigMaps
```

The attacker has inherited the **permissions of the shared identity**.

The attacker does not need to compromise `app-b`.

That is the blast-radius problem.

---

# 22. PROOF — the same identity can act on behalf of both workloads

From Kubernetes' perspective:

```text
app-a --> shared-app
app-b --> shared-app
```

There is no separate RBAC distinction between the two Pods.

RBAC sees:

```text
system:serviceaccount:sa-demo:shared-app
```

So the authorization decision is based on the identity, not on the application's business name.

Therefore:

```text
Same ServiceAccount
        =
Same RBAC permissions
```

---

# 23. This is the least-privilege violation

Suppose the real requirement is:

```text
Application A:
    get/list/watch pods
```

But we gave:

```text
get/list/watch/create/delete
    pods
    secrets
    configmaps
```

The difference is the security problem.

```text
                REQUIRED
                   |
                   v
              get pods
                   |
                   |
                   v
              GRANTED
                   |
       +-----------+-----------+
       |           |           |
    get pods    secrets     delete
                 access       pods
```

The application has more power than it needs.

That is:

> **Violation of least privilege.**

---

# 24. Clean up ONLY the bad shared design

Before continuing, remove:

```bash
kubectl delete pod app-a app-b -n sa-demo
kubectl delete rolebinding shared-app-binding -n sa-demo
kubectl delete role shared-app-role -n sa-demo
kubectl delete serviceaccount shared-app -n sa-demo
```

We intentionally leave:

```text
demo-secret
```

because we will use it to prove the secure design denies access.

---

# 25. Part D — Build the secure design

Now create separate identities.

```text
          Application A
               |
             app-a-sa
               |
             Role-A
               |
          get/list/watch Pods


          Application B
               |
             app-b-sa
               |
             Role-B
               |
          get ConfigMaps
```

There is no shared identity.

---

# 26. Create two dedicated ServiceAccounts

Create:

## `07-dedicated-serviceaccounts.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-a-sa
  namespace: sa-demo

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-b-sa
  namespace: sa-demo
```

Apply:

```bash
kubectl apply -f 07-dedicated-serviceaccounts.yaml
```

Verify:

```bash
kubectl get serviceaccount -n sa-demo
```

---

# 27. Give Application A only the permissions it needs

Assume Application A is a Pod-monitoring application.

Requirement:

```text
get pods
list pods
watch pods
```

Create:

## `08-app-a-role.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-a-role
  namespace: sa-demo
rules:
  - apiGroups: [""]
    resources:
      - pods
    verbs:
      - get
      - list
      - watch
```

Apply:

```bash
kubectl apply -f 08-app-a-role.yaml
```

---

# 28. Bind Application A's identity to its Role

Create:

## `09-app-a-rolebinding.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-a-binding
  namespace: sa-demo
subjects:
  - kind: ServiceAccount
    name: app-a-sa
    namespace: sa-demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: app-a-role
```

Apply:

```bash
kubectl apply -f 09-app-a-rolebinding.yaml
```

---

# 29. Give Application B a different permission set

Suppose Application B only needs to read ConfigMaps.

Create:

## `10-app-b-role.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-b-role
  namespace: sa-demo
rules:
  - apiGroups: [""]
    resources:
      - configmaps
    verbs:
      - get
      - list
      - watch
```

Apply:

```bash
kubectl apply -f 10-app-b-role.yaml
```

---

# 30. Bind Application B

Create:

## `11-app-b-rolebinding.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-b-binding
  namespace: sa-demo
subjects:
  - kind: ServiceAccount
    name: app-b-sa
    namespace: sa-demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: app-b-role
```

Apply:

```bash
kubectl apply -f 11-app-b-rolebinding.yaml
```

---

# 31. PROOF — Application A can do its job

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
yes
```

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
yes
```

```bash
kubectl auth can-i watch pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
yes
```

---

# 32. PROOF — Application A cannot read Secrets

This is the most important comparison with the bad design.

Run:

```bash
kubectl auth can-i get secrets \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
no
```

Try the specific Secret:

```bash
kubectl auth can-i get secret/demo-secret \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
no
```

Try deleting Pods:

```bash
kubectl auth can-i delete pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
no
```

Try creating Pods:

```bash
kubectl auth can-i create pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
no
```

---

# 33. PROOF — Application A cannot use Application B's permissions

Application B can read ConfigMaps:

```bash
kubectl auth can-i get configmaps \
  --as=system:serviceaccount:sa-demo:app-b-sa
```

Expected:

```text
yes
```

Now ask whether Application A can do the same:

```bash
kubectl auth can-i get configmaps \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected:

```text
no
```

This is the key isolation proof.

```text
app-a-sa                         app-b-sa
   |                                |
   v                                v
Role-A                           Role-B
   |                                |
pods get/list/watch             configmaps get/list/watch
   |                                |
   X                                X
configmaps                       pods
```

---

# 34. Create the secure Pods

Create:

## `12-secure-apps.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app-a
  namespace: sa-demo
spec:
  serviceAccountName: app-a-sa
  containers:
    - name: app
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          echo "Secure Application A"
          sleep 3600

---
apiVersion: v1
kind: Pod
metadata:
  name: secure-app-b
  namespace: sa-demo
spec:
  serviceAccountName: app-b-sa
  containers:
    - name: app
      image: curlimages/curl:8.10.1
      command:
        - sh
        - -c
        - |
          echo "Secure Application B"
          sleep 3600
```

Apply:

```bash
kubectl apply -f 12-secure-apps.yaml
```

---

# 35. PROOF — the Pods now have different identities

Run:

```bash
kubectl get pods -n sa-demo \
  -o custom-columns=NAME:.metadata.name,SERVICEACCOUNT:.spec.serviceAccountName
```

Expected:

```text
NAME            SERVICEACCOUNT
secure-app-a    app-a-sa
secure-app-b    app-b-sa
```

Compare this with the bad design:

```text
BAD:

app-a --> shared-app
app-b --> shared-app


GOOD:

app-a --> app-a-sa
app-b --> app-b-sa
```

---

# 36. PROOF — API request from secure Application A

Application A is allowed to list Pods.

Run:

```bash
kubectl exec -n sa-demo secure-app-a -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

  curl -sS --cacert "$CACERT" \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/sa-demo/pods
'
```

The API server should authorize the request.

Why?

```text
secure-app-a
     |
     v
app-a-sa
     |
     v
Role-A
     |
     v
get/list/watch pods
     |
     v
ALLOW
```

---

# 37. PROOF — secure Application A cannot read the Secret

Now perform the same type of request for Secrets:

```bash
kubectl exec -n sa-demo secure-app-a -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

  curl -i --cacert "$CACERT" \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/sa-demo/secrets/demo-secret
'
```

Expected:

```text
HTTP/1.1 403 Forbidden
```

This is the strongest proof in the demo.

The Pod has:

```text
valid ServiceAccount identity
```

but does not have:

```text
permission to read Secrets
```

Therefore:

```text
Authentication = SUCCESS
Authorization  = DENIED
Result         = 403 Forbidden
```

---

# 38. The complete attack comparison

## BAD

```text
              Attacker compromises app-a
                         |
                         v
                       app-a
                         |
                         v
                    shared-app
                         |
                         v
                    Broad Role
                         |
          +--------------+--------------+
          |              |              |
       Secrets          Pods        ConfigMaps
          |              |              |
       ALLOWED         ALLOWED         ALLOWED
```

Because `app-b` also uses:

```text
shared-app
```

the same permissions apply to both applications.

---

## GOOD

```text
              Attacker compromises app-a
                         |
                         v
                       app-a
                         |
                         v
                      app-a-sa
                         |
                         v
                       Role-A
                         |
             +-----------+-----------+
             |                       |
          Pods/get               Pods/list
             |
             X
          Secrets
             |
             X
       ConfigMaps
             |
             X
        Delete Pods
```

Application B has a completely different identity:

```text
app-b-sa
```

and therefore a different RBAC permission set.

---

# 39. Before vs after

| Test | Shared SA — BAD | Dedicated SA — GOOD |
|---|---:|---:|
| App A: get Pods | YES | YES |
| App A: list Pods | YES | YES |
| App A: read Secrets | YES | NO |
| App A: delete Pods | YES | NO |
| App A: create Pods | YES | NO |
| App A: access App B permissions | YES / same identity | NO |
| Least privilege | ❌ | ✅ |
| Blast radius | Large | Smaller |
| Identity isolation | ❌ | ✅ |

---

# 40. Why sharing a ServiceAccount is dangerous

The statement:

> "If an attacker compromises any Pod using that ServiceAccount, the attacker may inherit all permissions granted to that identity."

means exactly this:

```text
Pod A
  |
  +----------------+
                   |
Pod B              |
  |                |
  +-------> Same ServiceAccount
                   |
                   v
              Same RBAC
                   |
        +----------+----------+
        |          |          |
      Pods      Secrets    ConfigMaps
```

If Pod A is compromised:

```text
Compromise Pod A
       |
       v
Obtain/use Pod A's workload identity
       |
       v
Same ServiceAccount as Pod B
       |
       v
Same permissions
```

The attacker does not have to compromise Pod B.

That is why sharing a powerful ServiceAccount increases the blast radius.

---

# 41. Least privilege in simple language

Least privilege means:

> **Give the workload exactly the permissions it needs — no more.**

If the application needs:

```text
get pods
```

do not give:

```text
get secrets
delete pods
create pods
create deployments
modify RBAC
```

The ideal permission set is:

```text
                 Application
                      |
                      v
                ServiceAccount
                      |
                      v
                    Role
                      |
                +-----+-----+
                |           |
            get pods    list pods
                |
                +-- watch pods
```

Everything else should be denied.

---

# 42. Why a dedicated ServiceAccount is better

A dedicated ServiceAccount gives you an isolation boundary.

Instead of:

```text
20 applications
       |
       v
one shared powerful identity
```

use:

```text
App A --> SA-A --> Role-A
App B --> SA-B --> Role-B
App C --> SA-C --> Role-C
```

Now permissions can be changed independently.

For example:

```text
SA-A:
    pods get/list/watch

SA-B:
    configmaps get/list

SA-C:
    jobs get/list/create
```

---

# 43. Important: ServiceAccount alone does NOT provide security

This is a common misconception.

Creating:

```yaml
kind: ServiceAccount
```

does not automatically mean:

```text
secure
```

The security comes from:

```text
Dedicated identity
       +
Least-privilege RBAC
       +
Correct workload configuration
```

A ServiceAccount with:

```text
cluster-admin
```

is still extremely powerful.

For example:

```text
app-reader
    |
    v
ClusterRoleBinding
    |
    v
cluster-admin
```

is **not** least privilege.

The name `app-reader` does not make it a reader.

RBAC determines the actual permissions.

---

# 44. Role vs ClusterRole

## Role

Namespace-scoped permissions.

```text
sa-demo
   |
   +-- Role
       |
       +-- pods get/list/watch
```

Use a `Role` when the application only needs access inside one namespace.

## ClusterRole

A cluster-level RBAC object.

It can be used for broader permissions, including access to cluster-scoped resources such as Nodes.

Example:

```text
ClusterRole
    |
    +-- nodes/get
```

Do not use a ClusterRole/ClusterRoleBinding merely because it is convenient.

---

# 45. RoleBinding vs ClusterRoleBinding

## RoleBinding

Grants permissions in a namespace.

```text
ServiceAccount
      |
      v
RoleBinding
      |
      v
Role
      |
      v
sa-demo
```

## ClusterRoleBinding

Grants the referenced ClusterRole across the cluster.

```text
ServiceAccount
      |
      v
ClusterRoleBinding
      |
      v
ClusterRole
      |
      v
Cluster-wide permissions
```

Be particularly careful with:

```text
cluster-admin
```

because binding it to a workload identity can create a very large blast radius.

---

# 46. Admin kubeconfig vs ServiceAccount

Another dangerous pattern is:

```text
Application container
        |
        v
admin.kubeconfig
        |
        v
administrator identity
        |
        v
Kubernetes API
```

If the application is compromised:

```text
Attacker
   |
   v
Compromised application
   |
   v
Admin credential
   |
   v
Potentially broad cluster access
```

The safer model is:

```text
Application
    |
    v
Dedicated ServiceAccount
    |
    v
Least-privilege RBAC
    |
    v
Only required API operations
```

### Golden rule

> **Never solve an application's Kubernetes API requirement by placing a production administrator credential inside the application container.**

---

# 47. Extra hardening: disable automatic ServiceAccount token mounting when not needed

If an application does **not** need to call the Kubernetes API, consider:

```yaml
automountServiceAccountToken: false
```

Example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-api-access-app
  namespace: sa-demo
spec:
  automountServiceAccountToken: false

  containers:
    - name: app
      image: nginx:alpine
```

This is useful because:

```text
Application does not need Kubernetes API
                |
                v
Don't provide a workload API token unnecessarily
```

Important:

> This is an additional hardening measure. It does not replace RBAC when the application genuinely needs Kubernetes API access.

---

# 48. Modern ServiceAccount token behavior

Modern Kubernetes versions generally use **short-lived, projected ServiceAccount tokens** for Pods rather than requiring manually created long-lived token Secrets.

Inside a Pod you may find:

```text
/var/run/secrets/kubernetes.io/serviceaccount/
    |
    +-- ca.crt
    +-- namespace
    +-- token
```

Inspect:

```bash
kubectl exec -n sa-demo secure-app-a -- \
  ls -la /var/run/secrets/kubernetes.io/serviceaccount/
```

The exact token projection/mount behavior can vary by Kubernetes version and Pod configuration.

---

# 49. Useful RBAC investigation commands

## Who am I?

```bash
kubectl auth whoami
```

## Can the current user perform an operation?

```bash
kubectl auth can-i get pods
```

## Test a ServiceAccount

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

## List permissions

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

## Test another namespace

```bash
kubectl auth can-i get pods \
  -n default \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

Expected for our namespace-scoped Role:

```text
no
```

This demonstrates why namespace-scoped RBAC can reduce blast radius.

---

# 50. A useful troubleshooting sequence

When a workload receives:

```text
403 Forbidden
```

ask:

### Step 1 — Which ServiceAccount does the Pod use?

```bash
kubectl get pod secure-app-a -n sa-demo \
  -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

### Step 2 — What permissions does it have?

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

### Step 3 — Test the exact operation

```bash
kubectl auth can-i get pods \
  --as=system:serviceaccount:sa-demo:app-a-sa
```

### Step 4 — Inspect RoleBindings

```bash
kubectl get rolebinding -n sa-demo
```

### Step 5 — Inspect the Role

```bash
kubectl get role -n sa-demo
```

This separates:

```text
Authentication problem
```

from:

```text
Authorization/RBAC problem
```

---

# 51. Final security model

## BAD

```text
             Multiple Applications
                       |
                       v
               Shared ServiceAccount
                       |
                       v
                  Broad RBAC
                       |
       +---------------+---------------+
       |               |               |
    Secrets           Pods         Workloads
       |               |               |
       +---------------+---------------+
                       |
                 Large blast radius
```

## GOOD

```text
             Application A
                   |
                SA-A
                   |
                Role-A
                   |
          Minimum permissions


             Application B
                   |
                SA-B
                   |
                Role-B
                   |
          Minimum permissions
```

---

# 52. The core lesson

Remember these four statements:

```text
1. ServiceAccount = workload identity

2. RBAC = permissions assigned to that identity

3. RoleBinding = connects identity to permissions

4. Least privilege = give only the access actually required
```

And the security equation:

```text
Shared identity
      +
Excessive RBAC
      +
Compromised Pod
      =
Large blast radius
```

Whereas:

```text
Dedicated identity
      +
Least-privilege RBAC
      +
Compromised Pod
      =
Much smaller Kubernetes blast radius
```

---

# 53. Interview-ready explanation

### Q: Is it mandatory to explicitly specify a ServiceAccount?

**Answer:**

No. A Pod normally receives the namespace's `default` ServiceAccount when `serviceAccountName` is not specified. The security best practice is to use a **dedicated ServiceAccount** when a workload needs Kubernetes API permissions, rather than relying on a shared identity or giving excessive permissions to `default`.

### Q: What happens if two Pods use the same ServiceAccount?

**Answer:**

They use the same Kubernetes identity for RBAC purposes. Therefore, they effectively share that identity's permissions. If one Pod is compromised, an attacker who can use that workload identity may be able to perform all API operations authorized for that ServiceAccount.

### Q: Does a ServiceAccount automatically make a Pod secure?

**Answer:**

No. A ServiceAccount provides identity. RBAC determines what that identity can do. A ServiceAccount bound to `cluster-admin` is still highly privileged.

### Q: Why is a dedicated ServiceAccount better?

**Answer:**

It allows each workload to have an independent identity and an independently controlled least-privilege RBAC policy, reducing blast radius if a workload is compromised.

### Q: Why is `Role` often preferable to `ClusterRole`?

**Answer:**

When the workload only needs access inside one namespace, a namespace-scoped `Role` and `RoleBinding` limit the permission scope and reduce the potential blast radius.

### Q: Why should we avoid putting an admin kubeconfig inside a Pod?

**Answer:**

Because compromising the application can expose the administrator credential. The attacker may then inherit the administrator's broad Kubernetes permissions.

---

# 54. Cleanup

Delete the entire demo namespace:

```bash
kubectl delete namespace sa-demo
```

Verify:

```bash
kubectl get namespace sa-demo
```

Expected:

```text
Error from server (NotFound): namespaces "sa-demo" not found
```

---

# 55. Final demo checklist

Use this checklist while teaching the demo:

```text
[ ] Create sa-demo
[ ] Show default ServiceAccount
[ ] Create Pod without serviceAccountName
[ ] Prove Kubernetes assigns default
[ ] Explain why default is not automatically cluster-admin

[ ] Create shared-app ServiceAccount
[ ] Give shared-app intentionally broad permissions
[ ] Create harmless demo Secret
[ ] Create app-a and app-b using shared-app
[ ] Prove both Pods use the same identity
[ ] Prove shared identity can read Secret
[ ] Explain "compromise one Pod -> inherit shared identity permissions"

[ ] Remove bad shared configuration

[ ] Create app-a-sa
[ ] Create app-b-sa
[ ] Give each a different least-privilege Role
[ ] Create secure-app-a and secure-app-b
[ ] Prove identities are different
[ ] Prove app-a can read Pods
[ ] Prove app-a cannot read Secrets
[ ] Prove app-a cannot use app-b's ConfigMap permissions
[ ] Show 403 Forbidden from API request
[ ] Explain authentication vs authorization
[ ] Clean up namespace
```

---

# 56. One picture to remember

```text
                 KUBERNETES SECURITY


                         Pod
                          |
                          v
                  ServiceAccount
                     "WHO AM I?"
                          |
                          v
                    Authentication
                          |
                          v
                      RBAC Rules
                  "WHAT CAN I DO?"
                          |
                 +--------+--------+
                 |                 |
               ALLOW              DENY
                 |                 |
                 v                 v
          Kubernetes API      403 Forbidden


       BAD                          GOOD

 App A ----+                   App A ---- SA-A
           |                              |
 App B ----+                   App B ---- SA-B
           |                              |
           v                              v
      Shared SA                       Separate RBAC
           |                              |
      Broad RBAC                    Least privilege
           |                              |
           v                              v
    Large blast radius             Smaller blast radius
```

> **The goal is not merely to "use a ServiceAccount."**
>
> **The goal is to give every workload an appropriate identity and the minimum RBAC permissions it actually needs.**
