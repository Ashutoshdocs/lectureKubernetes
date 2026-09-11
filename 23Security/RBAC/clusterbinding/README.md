# Kubernetes RBAC — ClusterRoleBinding Demo (2 users)

A hands-on demo that grants **two users** (`carol` and `dave`) **read-only
visibility across the entire cluster** using one `ClusterRole` and one
`ClusterRoleBinding`.

---

## The one idea to take away

| | Namespaced (`Role` + `RoleBinding`) | Cluster-wide (`ClusterRole` + `ClusterRoleBinding`) |
|--|--|--|
| Scope | A single namespace | **Every** namespace |
| Cluster-scoped resources (nodes, PVs, namespaces) | ❌ cannot grant | ✅ can grant |
| `namespace:` field | Required | **None** |
| Typical use | One team in one namespace | Platform/ops roles, monitoring, auditors |

A `ClusterRoleBinding` is powerful: whatever the `ClusterRole` allows applies
**everywhere**. Use it only for permissions that genuinely need to be cluster-wide.

As with all cert auth: the certificate's `CN` becomes the **username**. Here we
bind the two users individually, so each just needs `CN=carol` / `CN=dave`.

```
  cert(CN=carol) ─┐
                  ├──> ClusterRoleBinding ──> ClusterRole "cluster-pod-viewer"
  cert(CN=dave)  ─┘        (all namespaces + nodes)
```

---

## Files in this demo

| File | What it is |
|------|-----------|
| `01-clusterrole-pod-viewer.yml` | ClusterRole: read pods/logs in all namespaces + read nodes |
| `02-clusterrolebinding-viewers.yml` | **Binds `carol` and `dave` cluster-wide** (the key file) |
| `test-workloads.yml` | `dev` + `prod` namespaces, one nginx pod in each |
| `generate-user-cert.sh` | Issues a client cert (`CN=<user>`) |
| `create-kubeconfig.sh` | Builds a kubeconfig from a user's cert |
| `setup-two-users.sh` | Onboards both `carol` and `dave` in one run |

---

## Prerequisites

- Admin/`root` shell on the **control-plane node**.
- Cluster CA at `/etc/kubernetes/pki/ca.crt` **and** `ca.key`.
- `kubectl` and `openssl` installed.
- Copy this folder onto the node, `cd` into it, and run `chmod +x *.sh` once.

---

## Steps of Execution

### 1. Create the ClusterRole and ClusterRoleBinding (admin)

```bash
kubectl apply -f 01-clusterrole-pod-viewer.yml
kubectl apply -f 02-clusterrolebinding-viewers.yml
```

Confirm the binding lists both users:

```bash
kubectl describe clusterrolebinding cluster-pod-viewers-binding
# Subjects:
#   User  carol
#   User  dave
```

### 2. Deploy test workloads in two namespaces (admin)

```bash
kubectl apply -f test-workloads.yml
```

### 3. Onboard both users

```bash
./setup-two-users.sh
```

This issues certs `CN=carol` and `CN=dave`, and writes each a kubeconfig at
`/home/<user>/.kube/config`. Both are already covered by the single
ClusterRoleBinding.

### 4. Verify cluster-wide access (as each user)

```bash
su - carol

# See pods in EVERY namespace — the cluster-wide part
kubectl get pods --all-namespaces        # ✅ shows nginx-dev AND nginx-prod
kubectl get pods -n prod                 # ✅ allowed
kubectl logs nginx-prod -n prod          # ✅ allowed

# Cluster-scoped resource a namespaced Role could never grant
kubectl get nodes                        # ✅ allowed

# Still read-only, everywhere
kubectl delete pod nginx-dev -n dev      # ❌ forbidden
kubectl get secrets -A                   # ❌ forbidden (not in the ClusterRole)
exit
```

Repeat for `dave` — identical result, because both share the one binding.

Declarative checks via impersonation (no kubeconfig needed):

```bash
kubectl auth can-i list pods -A --as=carol            # yes
kubectl auth can-i get nodes  --as=dave               # yes
kubectl auth can-i delete pods -A --as=carol          # no
```

---

## Add / remove a user on this binding

Because the subjects are listed individually, changing membership means editing
`02-clusterrolebinding-viewers.yml` and re-applying.

**Add a third user `erin`:**

```bash
# 1. add her as a subject in 02-clusterrolebinding-viewers.yml:
#    - kind: User
#      name: erin
#      apiGroup: rbac.authorization.k8s.io
kubectl apply -f 02-clusterrolebinding-viewers.yml

# 2. give her a cert + kubeconfig
./generate-user-cert.sh erin
./create-kubeconfig.sh erin
```

**Remove a user:** delete their subject block and re-apply, then delete their
cert files (see Cleanup). Note the revocation caveat below.

> Scaling tip: if this list keeps growing, switch the subject to a **Group**
> (e.g. `kind: Group, name: cluster-viewers`) and issue each user a cert with
> `O=cluster-viewers`. Then adding a user needs no binding edit — see the group
> binding demo.

---

## Safety notes

- **Least privilege.** A ClusterRoleBinding is cluster-wide by definition. This
  demo grants only read verbs on pods/logs/nodes, and deliberately **not**
  secrets. Never attach broad write verbs (or `cluster-admin`) to ordinary users.
- **Revocation.** Plain X.509 has no revocation list. Removing a subject from the
  binding stops new *authorization*, which is usually enough — but the cert
  itself remains valid until it expires. Prefer short-lived certs (small `days`)
  or an OIDC provider for real environments. This demo uses 90-day certs.
- Treat each kubeconfig like a password: the client key is embedded in it.

---

## Cleanup

```bash
kubectl delete -f test-workloads.yml
kubectl delete -f 02-clusterrolebinding-viewers.yml -f 01-clusterrole-pod-viewer.yml

for u in carol dave; do
  rm -f /etc/kubernetes/pki/${u}.{key,csr,crt}
  rm -rf /home/${u}/.kube
done
rm -f /etc/kubernetes/pki/ca.srl
```
