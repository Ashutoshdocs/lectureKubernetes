# Kubernetes RBAC — Group Binding Demo

A hands-on teaching demo that grants **read-only Pod access** to an entire
**group** (`dev`) instead of to individual users. The payoff: onboarding a new
developer is a single command and requires **zero changes to any RBAC file**.

---

## The one idea to take away

Kubernetes has no "user" objects. Identity comes from a CA-signed client
certificate, and RBAC decides what that identity may do. When you authenticate
with a certificate:

| Certificate field | Becomes in Kubernetes | Example |
|-------------------|-----------------------|---------|
| `CN` (Common Name)   | the **username** | `CN=bob`  → user `bob` |
| `O`  (Organization)  | a **group**      | `O=dev`   → group `dev` |

If your `RoleBinding` targets `kind: Group, name: dev`, then **every** user whose
certificate carries `O=dev` inherits those permissions automatically.

```
  cert(CN=alice, O=dev) ─┐
  cert(CN=bob,   O=dev) ─┼──> Group "dev" ──> RoleBinding ──> Role "pod-viewer"
  cert(CN=carol, O=dev) ─┘
```

Adding `carol` = issue her a cert with `O=dev`. That's it.

---

## Files in this demo

| File | What it is |
|------|-----------|
| `01-namespace.yml` | Creates the `dev` namespace |
| `02-role-pod-viewer.yml` | Role: `get/list/watch` pods, `get` pod logs |
| `03-rolebinding-dev-group.yml` | **Binds the Role to the `dev` group** (the key file) |
| `test-pod.yml` | An `nginx` pod to view during testing |
| `generate-user-cert.sh` | Issues a client cert: `CN=<user>`, `O=<group>` |
| `create-kubeconfig.sh` | Builds a kubeconfig from a user's cert |
| `add-user.sh` | One-shot onboarding = cert + kubeconfig (no RBAC change) |

---

## Prerequisites

- Admin/`root` shell on the **control-plane node**.
- Cluster CA present at `/etc/kubernetes/pki/ca.crt` **and** `ca.key`.
- `kubectl` and `openssl` installed.
- Copy this folder onto the control-plane node and `cd` into it.

Make the scripts executable once:

```bash
chmod +x *.sh
```

---

## Steps of Execution

### 1. Create the namespace, Role, and group RoleBinding (admin, once)

```bash
kubectl apply -f 01-namespace.yml
kubectl apply -f 02-role-pod-viewer.yml
kubectl apply -f 03-rolebinding-dev-group.yml
```

Confirm the binding targets a group:

```bash
kubectl describe rolebinding dev-pod-viewer-binding -n dev
# Subjects: Group  dev
```

### 2. Deploy a test pod (admin)

```bash
kubectl apply -f test-pod.yml
```

### 3. Onboard the first developer, `alice`

```bash
./add-user.sh alice
```

This issues a cert `CN=alice, O=dev`, builds `/home/alice/.kube/config`, and
switches to her context — **without touching any RBAC file**.

### 4. Verify alice's access (as alice)

```bash
su - alice

kubectl get pods            # ✅ allowed
kubectl logs nginx-demo     # ✅ allowed
kubectl delete pod nginx-demo   # ❌ forbidden (read-only)
kubectl get pods -n kube-system # ❌ forbidden (namespaced to dev)
exit
```

Declarative check:

```bash
kubectl auth can-i list pods --namespace dev \
  --as=alice --as-group=dev            # yes
kubectl auth can-i delete pods --namespace dev \
  --as=alice --as-group=dev            # no
```

> `--as` / `--as-group` let an admin *impersonate* a user/group to test RBAC
> without needing their kubeconfig.

---

## Add a New User and Let Them Use It

This is the part group binding makes trivial. To onboard `bob`:

### One command

```bash
./add-user.sh bob
```

That's the entire onboarding. Behind the scenes it:

1. Creates a Linux user `bob` (if missing) so the kubeconfig has an owner.
2. Issues `bob` a certificate with `CN=bob, O=dev`.
3. Builds `/home/bob/.kube/config` pinned to the `dev` namespace.

**No `kubectl apply`. No new RoleBinding. No edit to any YAML.** Because `bob`'s
cert says `O=dev`, the existing group binding already covers him.

### Confirm bob works

```bash
su - bob
kubectl get pods          # ✅ works immediately
kubectl auth can-i list pods   # yes
exit
```

### Hand off the kubeconfig

If `bob` works on his own machine rather than on the node, give him his
kubeconfig securely and have him place it at `~/.kube/config`:

```bash
# copy it off the node over SSH, then on bob's laptop:
export KUBECONFIG=~/.kube/config
kubectl get pods
```

The kubeconfig has the CA, client cert, and key **embedded**, so it's
self-contained — but for the same reason, treat it like a password.

### Put a user in a different group

Want `carol` to be an admin group instead? Issue her cert with a different `O`
and create a binding for that group once:

```bash
./generate-user-cert.sh carol admins
./create-kubeconfig.sh carol
# then apply a RoleBinding whose subject is Group "admins"
```

---

## User binding vs. Group binding

| | Bind to **User** | Bind to **Group** (this demo) |
|--|------------------|-------------------------------|
| Add a new person | Edit + re-apply a RoleBinding each time | Just issue a cert in the group |
| RoleBinding files | Grow with the team | One file, unchanged |
| Risk of drift | High (easy to forget a subject) | Low |
| Best for | One-off, special-case access | Teams / roles |

---

## How to Revoke Access (important caveat)

Plain X.509 auth has **no revocation list**. If someone leaves or a key leaks:

- Removing them from the group means re-issuing everyone else's certs under a
  new `O`, **or**
- Rotating the cluster CA (heavy).

For production, prefer **short-lived certificates** (small `days` value, or the
Kubernetes CertificateSigningRequest API) or an **OIDC** identity provider,
where group membership and revocation are managed centrally. This demo uses a
90-day cert lifetime to keep the blast radius small.

---

## Cleanup

```bash
kubectl delete -f test-pod.yml
kubectl delete -f 03-rolebinding-dev-group.yml -f 02-role-pod-viewer.yml
kubectl delete -f 01-namespace.yml

# per user
for u in alice bob; do
  rm -f /etc/kubernetes/pki/${u}.{key,csr,crt}
  rm -rf /home/${u}/.kube
done
rm -f /etc/kubernetes/pki/ca.srl
```
