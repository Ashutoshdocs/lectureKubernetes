# Give Linux User `james` Access to Kubernetes

## Objective

Understand why:

```bash
kubectl get pods
```

works for `root` but does not work for `james`, and how copying the kubeconfig allows `james` to use the same Kubernetes credentials.

---

## 1. Before the Change

First become root:

```bash
sudo su
```

Check:

```bash
whoami
echo $HOME
ls -l /root/.kube/config
```

Expected:

```text
root
/root
/root/.kube/config
```

Now test:

```bash
kubectl get pods
```

If `/root/.kube/config` contains valid Kubernetes credentials, the command works.

### Switch to James

```bash
su - james
```

Check:

```bash
whoami
echo $HOME
ls -l /home/james/.kube/config
```

The kubeconfig will normally be missing:

```text
/home/james/.kube/config: No such file or directory
```

Therefore:

```bash
kubectl get pods
```

will not use the kubeconfig that root was using.

---

# 2. Create `.kube` Directory for James

Switch back to root:

```bash
exit
```

Create the directory:

```bash
mkdir -p /home/james/.kube
```

This creates:

```text
/home/james/
└── .kube/
```

The `-p` option also creates missing parent directories if necessary.

---

# 3. Copy Root's kubeconfig

Run:

```bash
cp /root/.kube/config /home/james/.kube/config
```

Now:

```text
/home/james/
└── .kube/
    └── config
```

The file contains the Kubernetes cluster information and credentials that root was using.

---

# 4. Change Ownership

Run:

```bash
chown -R james:james /home/james/.kube
```

This changes the owner and group to:

```text
Owner: james
Group: james
```

The `-R` means recursively.

So the result is approximately:

```text
/home/james/.kube/
└── config
    Owner: james
    Group: james
```

---

# 5. Test After the Change

Switch to James:

```bash
su - james
```

Check:

```bash
whoami
echo $HOME
ls -l ~/.kube/config
```

You should now see:

```text
james
/home/james
/home/james/.kube/config
```

Then:

```bash
kubectl get pods
```

It should now work using the copied kubeconfig.

---

# Before vs After

## Before

```text
root
 |
 +-- /root/.kube/config
 |       |
 |       +-- Kubernetes credentials
 |
 +-- kubectl get pods  ---> WORKS


james
 |
 +-- /home/james/.kube/config
         |
         +-- DOES NOT EXIST
         
     kubectl get pods ---> DOES NOT WORK
```

## After

```text
root
 |
 +-- /root/.kube/config


james
 |
 +-- /home/james/.kube/config
         |
         +-- copy of root's kubeconfig
         |
         +-- kubectl get pods ---> WORKS
```

---

# Important Security Note

This setup gives `james` the **same Kubernetes credentials that root was using**.

Therefore, this is useful for demonstrating how kubeconfig works, but it is **not a proper multi-user RBAC setup**.

For a real Kubernetes multi-user environment, create separate credentials for:

```text
james
  |
  +-- own certificate/token
  |
  +-- own kubeconfig
  |
  +-- Kubernetes RBAC permissions
```

Then James can be given only the permissions he needs.

## Key Concept

```text
Linux user
    |
    v
/home/james/.kube/config
    |
    v
Kubernetes credentials
    |
    v
API Server
    |
    v
Kubernetes authorization / RBAC
```

**Copying the kubeconfig does not create a new Kubernetes user. It gives James access to the credentials already contained in that kubeconfig.**
