# Kubernetes Context Demo --- `dev` vs `prod`

A practical Kubernetes demo showing:

-   What a **Kubernetes context** really is
-   What `kubectl config use-context` actually switches
-   Why a context is more than just a namespace
-   Two identities: **`dev-user`** and **`prod-user`**
-   Two namespaces: **`dev`** and **`prod`**
-   RBAC isolation between them
-   How to verify which context, user, namespace and cluster are active
-   How to avoid accidentally running production commands

------------------------------------------------------------------------

## 1. The Big Idea

When you type:

``` bash
kubectl get pods
```

`kubectl` needs to answer four questions:

``` text
Which cluster?
Which credentials / user?
Which namespace?
Which API server?
```

A **context** packages the important pieces needed for a particular way
of talking to a Kubernetes cluster.

Conceptually:

``` text
Kubernetes Context
       |
       +---- Cluster
       |       |
       |       +---- API server
       |
       +---- User
       |       |
       |       +---- Credentials
       |
       +---- Namespace
```

A context is therefore essentially:

``` text
context = cluster + user + namespace
```

For this demo:

``` text
                 KUBERNETES CLUSTER
                         |
              +----------+----------+
              |                     |
           DEV                       PROD
              |                     |
          dev-user                prod-user
              |                     |
          namespace: dev        namespace: prod
              |                     |
        context: dev          context: prod
```

------------------------------------------------------------------------

# 2. What Does "Switch Context" Mean?

When you run:

``` bash
kubectl config use-context prod
```

you are **not switching Kubernetes clusters in the sense of moving
anything inside the cluster**.

You are telling your local `kubectl`:

> "For my next commands, use the configuration stored under the `prod`
> context."

For example:

``` bash
kubectl config use-context dev
kubectl get pods
```

means:

``` text
kubectl
  |
  +--> context = dev
          |
          +--> cluster = demo-cluster
          +--> user = dev-user
          +--> namespace = dev
```

Then:

``` bash
kubectl config use-context prod
kubectl get pods
```

means:

``` text
kubectl
  |
  +--> context = prod
          |
          +--> cluster = demo-cluster
          +--> user = prod-user
          +--> namespace = prod
```

The **cluster can be the same**.

What changes is the configuration `kubectl` uses to authenticate and
select the default namespace.

------------------------------------------------------------------------

# 3. The Two Users in This Demo

We will demonstrate two identities:

  Context   User          Namespace   Purpose
  --------- ------------- ----------- ---------------------
  `dev`     `dev-user`    `dev`       Developer
  `prod`    `prod-user`   `prod`      Production operator

The important point is:

> A context can select a different Kubernetes identity.

So this is not merely:

``` text
dev context = dev namespace
prod context = prod namespace
```

It is:

``` text
dev context  = demo-cluster + dev-user  + dev namespace
prod context = demo-cluster + prod-user + prod namespace
```

That distinction becomes very important when RBAC is involved.

------------------------------------------------------------------------

# 4. Important: Kubernetes "Users" vs Linux Users

A Kubernetes user is **not necessarily a Linux account**.

For example:

``` text
Linux:
azureuser
root
```

are operating-system users.

Kubernetes authentication may identify a caller as:

``` text
dev-user
prod-user
```

Those identities are presented to the Kubernetes API server through
credentials such as:

-   client certificates
-   bearer tokens
-   OIDC
-   cloud-provider authentication
-   other authentication mechanisms

Kubernetes does not normally maintain a built-in database of human
users.

For this demo, we use **ServiceAccounts as the credentials behind the
two demo identities**. This keeps the lab easy to reproduce while still
demonstrating how a context selects different credentials and RBAC
permissions.

------------------------------------------------------------------------

# 5. Prerequisites

You need:

``` bash
kubectl
```

and access to a Kubernetes cluster with permission to create:

-   namespaces
-   ServiceAccounts
-   Roles
-   RoleBindings

Check:

``` bash
kubectl version --client
kubectl cluster-info
```

Check the current context:

``` bash
kubectl config current-context
```

List all contexts:

``` bash
kubectl config get-contexts
```

------------------------------------------------------------------------

# 6. Create the Two Namespaces

Run these commands using an administrator context:

``` bash
kubectl create namespace dev
kubectl create namespace prod
```

Verify:

``` bash
kubectl get namespaces
```

You should see:

``` text
dev
prod
```

------------------------------------------------------------------------

# 7. Create the Two Demo Users

We will create one ServiceAccount in each namespace.

### Developer identity

``` bash
kubectl create serviceaccount dev-user -n dev
```

### Production identity

``` bash
kubectl create serviceaccount prod-user -n prod
```

Verify:

``` bash
kubectl get serviceaccounts -A
```

You should see entries similar to:

``` text
NAMESPACE   NAME
dev         dev-user
prod        prod-user
```

------------------------------------------------------------------------

# 8. Give `dev-user` Permissions Only in `dev`

Create a Role:

``` bash
kubectl create role dev-user-role \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services \
  -n dev
```

Bind it to the ServiceAccount:

``` bash
kubectl create rolebinding dev-user-binding \
  --role=dev-user-role \
  --serviceaccount=dev:dev-user \
  -n dev
```

This means:

``` text
dev-user
   |
   +---- Role: dev-user-role
   |
   +---- Namespace: dev
   |
   +---- Can manage selected resources
```

It does **not** give the identity permissions in `prod`.

------------------------------------------------------------------------

# 9. Give `prod-user` Permissions Only in `prod`

Create a Role:

``` bash
kubectl create role prod-user-role \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services \
  -n prod
```

Bind it:

``` bash
kubectl create rolebinding prod-user-binding \
  --role=prod-user-role \
  --serviceaccount=prod:prod-user \
  -n prod
```

Now:

``` text
dev-user  ---> permissions in dev
prod-user ---> permissions in prod
```

This is the security boundary for the demo.

------------------------------------------------------------------------

# 10. Create Tokens for the Two Users

Modern Kubernetes versions support:

``` bash
kubectl create token dev-user -n dev
```

and:

``` bash
kubectl create token prod-user -n prod
```

Save the returned values:

``` bash
DEV_TOKEN="$(kubectl create token dev-user -n dev)"
PROD_TOKEN="$(kubectl create token prod-user -n prod)"
```

You can verify that they are populated:

``` bash
echo "${#DEV_TOKEN}"
echo "${#PROD_TOKEN}"
```

Do **not** paste real production tokens into source control.

------------------------------------------------------------------------

# 11. Find the Current Cluster Information

First identify the cluster configuration used by your current
administrator context:

``` bash
kubectl config current-context
```

Then:

``` bash
kubectl config view --minify
```

You will see information similar to:

``` yaml
clusters:
- cluster:
    server: https://<api-server>
  name: <cluster-name>

contexts:
- context:
    cluster: <cluster-name>
    namespace: ...
    user: ...
  name: ...
```

For the lab, we will create a clean cluster entry called:

``` text
demo-cluster
```

Set its API server:

``` bash
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
```

You can check:

``` bash
echo "$SERVER"
```

------------------------------------------------------------------------

# 12. Create the Cluster Entry for the Demo

The easiest approach is to copy the CA information from the current
cluster.

Get the current cluster name:

``` bash
CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
```

Create a clean cluster entry:

``` bash
kubectl config set-cluster demo-cluster \
  --server="$SERVER" \
  --certificate-authority="$(
    kubectl config view --raw --minify \
      -o jsonpath='{.clusters[0].cluster.certificate-authority}' \
  )"
```

### If the kubeconfig uses embedded CA data

Many kubeconfigs use:

``` yaml
certificate-authority-data:
```

instead of:

``` yaml
certificate-authority:
```

In that case, use the existing cluster configuration rather than trying
to reference a local CA file.

A reliable lab method is to inspect:

``` bash
kubectl config view --raw --minify
```

and use the existing cluster entry's server and CA data when
constructing your contexts.

------------------------------------------------------------------------

# 13. Create the Two Credentials in kubeconfig

Create the development credential:

``` bash
kubectl config set-credentials dev-user \
  --token="$DEV_TOKEN"
```

Create the production credential:

``` bash
kubectl config set-credentials prod-user \
  --token="$PROD_TOKEN"
```

Now your kubeconfig contains two credential identities:

``` text
dev-user
prod-user
```

List them:

``` bash
kubectl config get-users
```

Depending on your kubectl version, the output may include:

``` text
dev-user
prod-user
```

------------------------------------------------------------------------

# 14. Create the `dev` Context

Run:

``` bash
kubectl config set-context dev \
  --cluster=demo-cluster \
  --user=dev-user \
  --namespace=dev
```

This creates:

``` text
context: dev

cluster:
    demo-cluster

user:
    dev-user

namespace:
    dev
```

------------------------------------------------------------------------

# 15. Create the `prod` Context

Run:

``` bash
kubectl config set-context prod \
  --cluster=demo-cluster \
  --user=prod-user \
  --namespace=prod
```

Now:

``` text
context: prod

cluster:
    demo-cluster

user:
    prod-user

namespace:
    prod
```

------------------------------------------------------------------------

# 16. View the Contexts

Run:

``` bash
kubectl config get-contexts
```

Conceptually, you should see:

``` text
CURRENT   NAME    CLUSTER        AUTHINFO    NAMESPACE
          dev     demo-cluster   dev-user    dev
          prod    demo-cluster   prod-user   prod
```

After selecting one, a `*` appears under `CURRENT`.

For example:

``` text
CURRENT   NAME    CLUSTER        AUTHINFO    NAMESPACE
*         dev     demo-cluster   dev-user    dev
          prod    demo-cluster   prod-user   prod
```

------------------------------------------------------------------------

# 17. Switch to DEV

Run:

``` bash
kubectl config use-context dev
```

Output:

``` text
Switched to context "dev".
```

Check:

``` bash
kubectl config current-context
```

Expected:

``` text
dev
```

Now:

``` bash
kubectl get pods
```

uses:

``` text
cluster    = demo-cluster
user       = dev-user
namespace  = dev
```

------------------------------------------------------------------------

# 18. Switch to PROD

Run:

``` bash
kubectl config use-context prod
```

Then:

``` bash
kubectl config current-context
```

Expected:

``` text
prod
```

Now:

``` bash
kubectl get pods
```

uses:

``` text
cluster    = demo-cluster
user       = prod-user
namespace  = prod
```

The command did not change:

``` bash
kubectl get pods
```

The **context behind the command changed**.

------------------------------------------------------------------------

# 19. Demonstrate the Namespace Difference

Create a test pod in each namespace using an administrator context:

``` bash
kubectl run dev-nginx \
  --image=nginx \
  -n dev
```

and:

``` bash
kubectl run prod-nginx \
  --image=nginx \
  -n prod
```

Now switch to dev:

``` bash
kubectl config use-context dev
```

Run:

``` bash
kubectl get pods
```

You should see the pod in:

``` text
dev
```

Now switch:

``` bash
kubectl config use-context prod
```

Run:

``` bash
kubectl get pods
```

You should see the pod in:

``` text
prod
```

Same command:

``` bash
kubectl get pods
```

Different result because the context has a different default namespace
and identity.

------------------------------------------------------------------------

# 20. Prove the Users Are Actually Different

This is the most important part of the demo.

Switch to:

``` bash
kubectl config use-context dev
```

Try to read pods in `dev`:

``` bash
kubectl get pods
```

This should work.

Now explicitly ask for `prod`:

``` bash
kubectl get pods -n prod
```

This should be denied because `dev-user` has not been granted
permissions in `prod`.

You may see an error similar to:

``` text
Error from server (Forbidden):
pods is forbidden:
User "system:serviceaccount:dev:dev-user"
cannot list resource "pods" in namespace "prod"
```

That proves:

``` text
dev-user != prod-user
```

and:

``` text
namespace selection != authorization
```

The context chooses the credentials, but **RBAC determines what those
credentials are allowed to do**.

------------------------------------------------------------------------

# 21. Prove the Production User

Switch:

``` bash
kubectl config use-context prod
```

Run:

``` bash
kubectl get pods
```

This works because:

``` text
prod-user
    |
    +---- RoleBinding
              |
              +---- prod-user-role
                        |
                        +---- namespace: prod
```

Now try:

``` bash
kubectl get pods -n dev
```

This should be denied.

So:

``` text
prod-user ---> allowed in prod
prod-user ---> denied in dev
```

------------------------------------------------------------------------

# 22. A Very Important Difference

Do not confuse these two ideas:

### Context

Answers:

> "Which cluster, credentials and default namespace should kubectl use?"

### RBAC

Answers:

> "What is that authenticated identity allowed to do?"

Therefore:

``` text
Context
   |
   +--> chooses identity
   |
   +--> chooses cluster
   |
   +--> chooses default namespace

RBAC
   |
   +--> decides permissions
```

Changing context does **not** grant permissions.

------------------------------------------------------------------------

# 23. What Exactly Happens During `use-context`?

Suppose your kubeconfig contains:

``` yaml
contexts:

- name: dev
  context:
    cluster: demo-cluster
    user: dev-user
    namespace: dev

- name: prod
  context:
    cluster: demo-cluster
    user: prod-user
    namespace: prod
```

When you run:

``` bash
kubectl config use-context dev
```

kubectl changes the `current-context` value in your kubeconfig:

``` yaml
current-context: dev
```

Then:

``` bash
kubectl get pods
```

looks up:

``` text
current-context
       |
       v
      dev
       |
       +---- cluster: demo-cluster
       +---- user: dev-user
       +---- namespace: dev
```

When you run:

``` bash
kubectl config use-context prod
```

the configuration effectively becomes:

``` yaml
current-context: prod
```

Then:

``` text
current-context
       |
       v
      prod
       |
       +---- cluster: demo-cluster
       +---- user: prod-user
       +---- namespace: prod
```

------------------------------------------------------------------------

# 24. Context Is Stored in kubeconfig

Usually:

``` bash
~/.kube/config
```

For the current Linux user.

Check:

``` bash
echo "$KUBECONFIG"
```

If nothing is printed, kubectl normally falls back to:

``` text
$HOME/.kube/config
```

This matters enormously when using:

``` bash
sudo
sudo su
su -
```

because changing Linux users can change:

``` text
$HOME
```

and therefore change which kubeconfig is automatically read.

For example:

``` text
azureuser
   |
   +--> $HOME=/home/azureuser
   |
   +--> /home/azureuser/.kube/config


root
   |
   +--> $HOME=/root
   |
   +--> /root/.kube/config
```

So a context belongs to the kubeconfig being used by that `kubectl`
process.

------------------------------------------------------------------------

# 25. Useful Commands for Understanding Contexts

### Show current context

``` bash
kubectl config current-context
```

### List contexts

``` bash
kubectl config get-contexts
```

### Display the complete kubeconfig

``` bash
kubectl config view
```

### Display the current context

``` bash
kubectl config view --minify
```

### See the current namespace

``` bash
kubectl config view --minify -o jsonpath='{..namespace}'; echo
```

### See current context and user

``` bash
kubectl config view --minify -o jsonpath='{.contexts[0].name}{"\n"}{.contexts[0].context.user}{"\n"}'
```

### Switch

``` bash
kubectl config use-context dev
```

or:

``` bash
kubectl config use-context prod
```

------------------------------------------------------------------------

# 26. One-Command Safety Check

Before running a dangerous command, check:

``` bash
kubectl config current-context
```

Then:

``` bash
kubectl config view --minify
```

A useful habit is:

``` bash
kubectl config current-context && kubectl get ns
```

For production work, always verify the context before commands such as:

``` bash
kubectl delete
kubectl apply
kubectl rollout restart
kubectl scale
```

------------------------------------------------------------------------

# 27. Context Does Not Create a New Cluster

This is a common beginner misunderstanding.

Suppose:

``` text
dev context
prod context
```

both point to:

``` text
demo-cluster
```

There is still only:

``` text
ONE Kubernetes cluster
```

You simply have two ways of accessing it:

``` text
                  demo-cluster
                       |
             +---------+---------+
             |                   |
           dev                 prod
             |                   |
         dev-user            prod-user
             |                   |
          namespace           namespace
             dev                 prod
```

------------------------------------------------------------------------

# 28. Context Can Also Point to Different Clusters

Contexts do not have to share a cluster.

For example:

``` text
context: dev
    cluster: dev-cluster
    user: developer
    namespace: dev

context: prod
    cluster: prod-cluster
    user: production-admin
    namespace: prod
```

Then switching context can actually change the API server being
contacted:

``` text
kubectl config use-context dev
       |
       +----> dev-cluster API server


kubectl config use-context prod
       |
       +----> prod-cluster API server
```

This is one reason context mistakes can be dangerous.

------------------------------------------------------------------------

# 29. The Mental Model to Remember

Think of a context as a **saved connection profile**.

For this lab:

``` text
                    CONTEXT
                       |
          +------------+------------+
          |            |            |
       CLUSTER        USER       NAMESPACE
          |            |            |
   demo-cluster     dev-user       dev
```

versus:

``` text
                    CONTEXT
                       |
          +------------+------------+
          |            |            |
       CLUSTER        USER       NAMESPACE
          |            |            |
   demo-cluster    prod-user      prod
```

The context tells `kubectl`:

``` text
"Talk to THIS cluster,
 using THESE credentials,
 with THIS namespace as the default."
```

------------------------------------------------------------------------

# 30. Complete Demo Flow

## Step 1 --- Create namespaces

``` bash
kubectl create namespace dev
kubectl create namespace prod
```

## Step 2 --- Create identities

``` bash
kubectl create serviceaccount dev-user -n dev
kubectl create serviceaccount prod-user -n prod
```

## Step 3 --- Create RBAC

``` bash
kubectl create role dev-user-role \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services \
  -n dev

kubectl create rolebinding dev-user-binding \
  --role=dev-user-role \
  --serviceaccount=dev:dev-user \
  -n dev
```

``` bash
kubectl create role prod-user-role \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services \
  -n prod

kubectl create rolebinding prod-user-binding \
  --role=prod-user-role \
  --serviceaccount=prod:prod-user \
  -n prod
```

## Step 4 --- Create tokens

``` bash
DEV_TOKEN="$(kubectl create token dev-user -n dev)"
PROD_TOKEN="$(kubectl create token prod-user -n prod)"
```

## Step 5 --- Configure credentials

``` bash
kubectl config set-credentials dev-user --token="$DEV_TOKEN"
kubectl config set-credentials prod-user --token="$PROD_TOKEN"
```

## Step 6 --- Create contexts

``` bash
kubectl config set-context dev \
  --cluster=demo-cluster \
  --user=dev-user \
  --namespace=dev
```

``` bash
kubectl config set-context prod \
  --cluster=demo-cluster \
  --user=prod-user \
  --namespace=prod
```

## Step 7 --- Test DEV

``` bash
kubectl config use-context dev
kubectl config current-context
kubectl get pods
kubectl get pods -n prod
```

Expected:

``` text
dev command          -> allowed
explicit prod access -> Forbidden
```

## Step 8 --- Test PROD

``` bash
kubectl config use-context prod
kubectl config current-context
kubectl get pods
kubectl get pods -n dev
```

Expected:

``` text
prod command         -> allowed
explicit dev access  -> Forbidden
```

------------------------------------------------------------------------

# 31. Final Learning Summary

### What is a context?

A context is a kubeconfig entry that associates:

``` text
cluster + user + namespace
```

### What does switching context mean?

``` bash
kubectl config use-context prod
```

means:

> Make `prod` the current kubeconfig context used by kubectl.

### Does switching context switch Kubernetes itself?

**No.**

It changes which configuration `kubectl` uses.

### Can two contexts use the same cluster?

**Yes.**

Our demo does exactly that:

``` text
dev  ---> demo-cluster
prod ---> demo-cluster
```

### Can two contexts use different users?

**Yes.**

Our demo:

``` text
dev  ---> dev-user
prod ---> prod-user
```

### Can two contexts use different namespaces?

**Yes.**

Our demo:

``` text
dev  ---> namespace dev
prod ---> namespace prod
```

### Does context provide authorization?

**No.**

RBAC provides authorization.

``` text
Context
   |
   +--> Which identity?
   +--> Which cluster?
   +--> Which default namespace?

RBAC
   |
   +--> What can that identity do?
```

------------------------------------------------------------------------

# 32. The One Diagram to Remember

``` text
                         kubectl
                            |
                            |
                 current-context
                            |
             +--------------+--------------+
             |                             |
          context: dev                 context: prod
             |                             |
       +-----+-----+                 +-----+-----+
       |     |     |                 |     |     |
   cluster  user namespace        cluster  user namespace
       |     |     |                 |     |     |
       |  dev-user dev               | prod-user prod
       |                             |
       +-------------+---------------+
                     |
                demo-cluster
                     |
              Kubernetes API
                     |
                  RBAC
                /       \
             allowed   denied
                |         |
               dev       prod
```

The key lesson is:

> **A context is not a namespace, not a user, and not a cluster. It is a
> kubeconfig mapping that tells kubectl which cluster, credentials and
> default namespace to use together.**

And:

``` bash
kubectl config use-context dev
```

or:

``` bash
kubectl config use-context prod
```

simply changes the **current context** used by subsequent `kubectl`
commands.
