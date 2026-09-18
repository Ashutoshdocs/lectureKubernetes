# Kubernetes RBAC — Read-Only Pod Access for `alice`

This project provisions a developer user (`alice`) with **read-only access to Pods** in the
`dev` namespace using X.509 client-certificate authentication and namespaced RBAC.

---

## Overview

| Layer | File | Purpose |
|-------|------|---------|
| Identity | `generate_certificate` | Issues an X.509 client cert for `alice` signed by the cluster CA (`CN=alice`, `O=dev`) |
| Access config | `kubeconfigfor_alice.sh` | Builds `alice`'s `kubeconfig`, pinned to the `dev` namespace |
| Permission (Role) | `role-pod-viewer.yml` | Namespaced Role: `get/list/watch` pods, `get` pod logs |
| Permission (Binding) | `rolebinding-pod-viewer.yml` | Binds user `alice` to the `pod-viewer` Role in `dev` |
| Test workload | `simple_pod.yml` | An `nginx` pod in `dev` for testing |
| Test workload | `alicepod.yml` | A `redis` pod in `dev` (⚠️ contains a plaintext password) |

**How Kubernetes reads the certificate:** the certificate subject's Common Name (`CN=alice`)
becomes the **username** and the Organization (`O=dev`) becomes a **group**. Kubernetes has no
"user" objects — identity is asserted entirely by the CA-signed cert, and authorization is then
decided by RBAC.

---

## Prerequisites

- A running cluster where you have `root`/admin access on the **control-plane node**.
- The cluster CA present at `/etc/kubernetes/pki/ca.crt` and `/etc/kubernetes/pki/ca.key`.
- `openssl` and `kubectl` installed.
- A Linux user `alice` already existing on the node (for file ownership).
- A `dev` namespace (create it if missing: `kubectl create namespace dev`).

---

## Steps of Execution

Run steps 1–4 **as admin on the control-plane node**, in order.

### 1. Generate alice's client certificate

```bash
chmod +x generate_certificate
./generate_certificate
```

This creates `alice.key`, `alice.csr`, and a CA-signed `alice.crt` (valid 365 days) inside
`/etc/kubernetes/pki`.

> Tip: give the script a shebang (`#!/bin/bash`) and rename it to `generate_certificate.sh`
> for clarity.

### 2. Create the namespace (if it doesn't exist)

```bash
kubectl create namespace dev
```

### 3. Apply the Role and RoleBinding

```bash
kubectl apply -f role-pod-viewer.yml
kubectl apply -f rolebinding-pod-viewer.yml
```

### 4. Generate alice's kubeconfig

```bash
chmod +x kubeconfigfor_alice.sh
# Edit CONTROL_PLANE_IP inside the script first if 172.16.0.4 is not correct.
./kubeconfigfor_alice.sh
```

This writes `/home/alice/.kube/config`, embeds the certs, sets the `alice-context`
(namespace `dev`), and chowns the file to `alice`.

### 5. Deploy test workloads (as admin)

`alice` can only **view** pods, so an admin must create them:

```bash
kubectl apply -f simple_pod.yml
kubectl apply -f alicepod.yml
```

### 6. Verify alice's access (as alice)

```bash
su - alice

# These should SUCCEED
kubectl get pods
kubectl logs nginx-pod

# These should be FORBIDDEN (proves least privilege)
kubectl delete pod nginx-pod
kubectl create -f simple_pod.yml
kubectl get pods -n kube-system
```

You can also confirm permissions declaratively:

```bash
kubectl auth can-i list pods --namespace dev        # yes
kubectl auth can-i delete pods --namespace dev      # no
kubectl auth can-i get pods --namespace kube-system # no
```

---

## RBAC Role Binding — Rating

**Overall: 7 / 10 — Good, well-scoped, but with meaningful hardening gaps.**

### What's done well ✅

- **Least-privilege verbs.** Only `get`, `list`, `watch` on pods and `get` on `pods/log`.
  No `create`, `update`, `delete`, or `exec`. This is genuinely read-only.
- **Namespaced, not cluster-wide.** A `Role` + `RoleBinding` (rather than `ClusterRole` +
  `ClusterRoleBinding`) correctly confines `alice` to the `dev` namespace.
- **Well-formed manifests.** `roleRef` and `subjects` use the correct `apiGroup`
  (`rbac.authorization.k8s.io`), the kinds are correct, and the binding points at a Role that
  actually exists.
- **Explicit subject.** It binds a single named user rather than a wildcard or an overly
  broad system group.

### Where it loses points ⚠️

1. **Binds an individual user, not a group.** The cert already carries `O=dev`, so binding to
   `kind: Group, name: dev` would scale to the whole team and avoid re-editing the binding for
   every new developer. Per-user bindings become unmanageable as the team grows.
2. **Certificate auth can't be revoked.** Vanilla Kubernetes has no CRL/OCSP. If `alice`
   leaves or her key leaks, the only true fix is rotating the cluster CA. The **365-day**
   lifetime makes this worse — prefer short-lived certs (e.g. via the CertificateSigningRequest
   API) or an OIDC identity provider.
3. **Read access still leaks the redis secret.** `alicepod.yml` stores `REDIS_PASSWORD` as a
   plaintext env var. Because `alice` can `get pods`, she can run
   `kubectl get pod redis-pod -o yaml` and read the password. The RBAC rule is fine; the
   *workload design* undermines it. Move the password into a `Secret` and restrict who can read
   Secrets (this Role grants no Secret access, which is correct).
4. **No `resourceNames` scoping.** `alice` can view *every* pod in `dev`. If the intent were to
   scope her to specific pods, `resourceNames` could narrow it (though this doesn't apply to
   `list`/`watch`, so grouping by namespace is usually the better boundary).

### Suggested improvement (bind to the group instead)

```yaml
subjects:
- kind: Group
  name: dev            # matches O=dev in the client certificate
  apiGroup: rbac.authorization.k8s.io
```

---

## Security Recommendations (priority order)

1. Move `REDIS_PASSWORD` out of the pod spec into a Kubernetes `Secret`.
2. Shorten the certificate lifetime and adopt a rotation/revocation story (CSR API or OIDC).
3. Bind to the `dev` **group** rather than the individual user for maintainability.
4. Keep `alice.key` readable only by `alice` (`chmod 600`), and never commit it to source control.
5. Periodically audit with `kubectl auth can-i --list --namespace dev` as `alice`.

---

## Cleanup

```bash
kubectl delete -f alicepod.yml -f simple_pod.yml
kubectl delete -f rolebinding-pod-viewer.yml -f role-pod-viewer.yml
rm -f /etc/kubernetes/pki/alice.{key,csr,crt,srl}
rm -rf /home/alice/.kube
```
