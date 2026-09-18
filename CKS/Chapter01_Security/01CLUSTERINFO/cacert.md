# Understanding `ca.crt` — The Root of Trust in Kubernetes

> **One-line takeaway:** `ca.crt` is the single certificate that every component in your
> cluster trusts. It is the anchor that lets the API server, kubelets, controllers,
> `etcd`, and your own `kubectl` prove their identities to each other over TLS — without
> ever sharing a password.

---

## 1. Where it lives

On a control-plane node created with `kubeadm`, the cluster's Public Key Infrastructure
(PKI) lives here:

```
/etc/kubernetes/pki/
├── ca.crt                        # Cluster root CA certificate  ← THIS FILE
├── ca.key                        # Cluster root CA private key   ← THE CROWN JEWEL
├── apiserver.crt / .key          # API server's TLS serving cert (signed by ca.crt)
├── apiserver-kubelet-client.*    # API server → kubelet client auth (signed by ca.crt)
├── apiserver-etcd-client.*       # API server → etcd client auth
├── front-proxy-ca.crt / .key     # Separate CA for the aggregation layer
├── front-proxy-client.crt / .key # Front-proxy client cert
├── sa.key / sa.pub               # ServiceAccount token SIGNING keypair (not a cert)
└── etcd/                         # etcd's own CA and peer/server/client certs
```

Two important notes:

- `ca.crt` and `ca.key` are a **pair**. The `.crt` is public and gets copied everywhere.
  The `.key` is secret and must **never** leave the control-plane node.
- `etcd/` has its **own** CA. A production cluster often runs the etcd PKI separately so
  that compromising one does not automatically compromise the other.

---

## 2. What is actually inside `ca.crt`?

Decode any CA with:

```bash
openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -text
```

A typical kubeadm cluster CA looks like this:

```
subject = CN = kubernetes
issuer  = CN = kubernetes          # subject == issuer  →  SELF-SIGNED (it is the root)
notBefore = Aug 19 21:26:36 2026 GMT
notAfter  = Aug 16 21:31:36 2036 GMT   # ~10 year lifetime — CAs are long-lived on purpose

X509v3 Basic Constraints: critical
    CA:TRUE                         # ← allowed to SIGN other certificates
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment, Certificate Sign
X509v3 Subject Alternative Name:
    DNS:kubernetes
```

The two fields that make it a Certificate Authority:

| Field | Value | Meaning |
|-------|-------|---------|
| `Basic Constraints` | `CA:TRUE` | This certificate is permitted to issue/sign other certificates. |
| `Key Usage` | `Certificate Sign` | It may sign the certificates of leaf identities (API server, kubelets, users). |
| `issuer == subject` | `CN = kubernetes` | It is **self-signed** — it sits at the top of the chain, so nothing signs it. |

A "leaf" certificate (like `apiserver.crt`) would instead show `CA:FALSE` and an issuer of
`CN = kubernetes`, proving it was signed *by* this CA.

---

## 3. Why the whole cluster depends on it

Kubernetes secures every internal connection with **mutual TLS (mTLS)**. Both sides of a
connection present a certificate, and each side verifies that the other's certificate was
**signed by a CA it trusts**. That trusted CA is `ca.crt`.

```
                          ca.crt  (root of trust)
                             │  signs
        ┌────────────────────┼─────────────────────────┐
        ▼                    ▼                          ▼
  apiserver.crt      apiserver-kubelet-client.crt   your user cert
  (API server        (API server proves itself      (kubectl proves
   proves itself       to each kubelet)               YOU to the API)
   to clients)
```

Concrete trust checks that happen constantly:

- **`kubectl` → API server:** your kubeconfig contains `certificate-authority-data`, which
  is just this `ca.crt` base64-encoded. Your client uses it to confirm the API server's
  serving cert is legitimate — this is what stops a man-in-the-middle from impersonating
  your cluster.
- **API server → kubelet:** the API server presents `apiserver-kubelet-client.crt`; the
  kubelet accepts it only because it chains back to `ca.crt`.
- **Client-certificate authentication:** a user presenting a cert with
  `CN=alice, O=developers` is authenticated as user `alice` in group `developers` — *only*
  because that cert was signed by this CA. The CN becomes the username; the O becomes the
  group. RBAC then decides what `alice` may do.

Remove or corrupt `ca.crt`, and components can no longer verify one another — TLS
handshakes fail and the control plane stops trusting itself.

---

## 4. How `ca.crt` connects to your kubeconfig

Open `~/.kube/config` and you'll find:

```yaml
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBD...   # <-- base64 of ca.crt
    server: https://<api-server>:6443
  name: kubernetes
```

Prove it to yourself:

```bash
# Extract the CA embedded in your kubeconfig and decode it
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d | openssl x509 -noout -subject -fingerprint -sha256

# Compare against the CA on the control-plane node
openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -fingerprint -sha256
```

The SHA-256 fingerprints will match. That match is *the entire reason* your laptop trusts
that remote API server.

---

## 5. The security stakes — why `ca.key` is the crown jewel

`ca.crt` (public) is safe to distribute. `ca.key` (private) is catastrophic to leak.

Anyone holding `ca.key` can **sign a brand-new certificate for any identity they want**,
including the built-in super-user group:

```bash
# THIS IS WHAT AN ATTACKER WITH ca.key CAN DO — do not run in production
openssl req -new -key attacker.key -subj "/CN=attacker/O=system:masters" -out attacker.csr
openssl x509 -req -in attacker.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out attacker.crt -days 365
```

A certificate with `O=system:masters` maps to a group that is bound to `cluster-admin` by
default. That cert **bypasses RBAC entirely** and grants total control of the cluster —
no API server flag can revoke a validly signed cert short of rotating the whole CA.

**Rules that follow from this:**

- `/etc/kubernetes/pki` is `root`-owned; `ca.key` should be `0600` and never copied off the
  node, never committed to Git, never pasted into chat or tickets.
- Losing `ca.key` = rebuild trust from scratch. Rotating a cluster CA means re-issuing
  **every** certificate in the cluster and redistributing the new `ca.crt` to all clients.
- Distributing `ca.crt` is fine and expected. Distributing `ca.key` is a breach.

---

## 6. Certificate expiry — the operational gotcha

- The **CA** is valid ~10 years (see `notAfter` above), so it rarely expires unexpectedly.
- The **leaf certs it signs** (API server, kubelet clients, etc.) are valid only **~1 year**
  by default. Clusters that are never upgraded often die on their first birthday when these
  leaf certs silently expire.

Check everything at once:

```bash
kubeadm certs check-expiration
```

Renew the leaf certs (this does **not** touch the CA):

```bash
kubeadm certs renew all
```

Because the CA does not change during renewal, existing clients keep trusting the cluster —
that stability is another reason the CA has a long lifetime.

---

## 7. Handy commands cheat-sheet

```bash
# Inspect the CA fully
openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -text

# Just the essentials
openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -issuer -dates

# Confirm it is a CA (look for CA:TRUE)
openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -ext basicConstraints,keyUsage

# Verify a leaf cert was signed by this CA
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/apiserver.crt

# See which identity a client cert authenticates as (CN = user, O = group)
openssl x509 -in /path/to/user.crt -noout -subject

# Check expiry of all cluster certs
kubeadm certs check-expiration
```

---

## 8. Mental model to remember

```
        ca.crt = the notary everyone in the cluster agrees to trust
        ca.key = the notary's signing stamp (guard with your life)

   "Do I trust you?"  →  "Is your certificate signed by ca.crt?"  →  yes / no
   "Who are you?"     →  the CN/O in your signed certificate       →  user / groups
   "What may you do?" →  RBAC decides (a separate question)
```

- **Authentication** (identity) comes from certs signed by the CA.
- **Authorization** (permissions) comes from RBAC.
- The CA answers *"is this identity real?"* — never *"what is it allowed to do?"*

> **Bottom line:** `ca.crt` is the foundation of trust for the entire cluster. Everything —
> API server, kubelets, controllers, and your own `kubectl` — believes in each other only
> because their certificates trace back to this one file. Protect its private key above all
> else.
