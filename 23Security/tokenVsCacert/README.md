# Kubernetes Client Authentication: Tokens vs. Client Certificates

A hands-on, runnable demo that teaches the **two most common ways a client proves
its identity to the Kubernetes API server** — and, more importantly, *when to use
which*.

Both demos target the same tiny goal (read-only access to pods in one namespace)
so the **only** thing that changes between them is *how the client authenticates*.

---

## 1. The mental model (read this first)

Every request to `kube-apiserver` goes through three gates, in order:

```
   ┌───────────────┐     ┌────────────────┐     ┌─────────────────┐
   │ AUTHENTICATION │ --> │ AUTHORIZATION  │ --> │ ADMISSION       │
   │  "Who are you?"│     │ "Can you do X?"│     │ "Is X allowed by│
   │                │     │   (RBAC)       │     │  policy?"       │
   └───────────────┘     └────────────────┘     └─────────────────┘
```

This demo is about the **first gate only**. Both a token and a certificate are
just two different ways of answering *"Who are you?"*. Once you're identified,
**RBAC** (the second gate) decides what you may do — and RBAC is *identical*
regardless of how you logged in. That separation is the single most important
idea in the whole demo.

> **There is no `User` object in Kubernetes.** The cluster does not store a list
> of humans. A "user" is simply whatever identity your credential asserts —
> a username string from a signed cert, or a subject embedded in a token.
> Authorization is then attached to that string (or its group) via RBAC.

### The two mechanisms in one sentence each

| | How the client proves identity | Who owns the trust root |
|---|---|---|
| **Token (bearer)** | Sends `Authorization: Bearer <JWT>` on every request | The **cluster** signs & controls the token |
| **Client certificate** | Presents an X.509 cert during the **TLS handshake** (mTLS) | The **cluster CA** signed the cert; identity is the cert's `CN`/`O` |

---

## 2. Prerequisites

- A Kubernetes cluster where you are **cluster-admin** (any of: `minikube`,
  `kind`, `k3s`/`k3d`, Docker Desktop, EKS, GKE, AKS).
- `kubectl` v1.24+ configured and pointing at that cluster.
- `openssl` and `bash` (Demo 2 only).

> Fastest local setup: `minikube start` **or** `kind create cluster`.

Sanity check:

```bash
kubectl auth whoami          # should show your admin identity
kubectl get nodes            # should list at least one node
```

---

## 3. Repository layout

```
k8s-auth-demo/
├── README.md                     <- you are here
├── run-all.sh                    <- seeds a pod + runs BOTH demos
├── cleanup-all.sh                <- tears everything down
├── rbac/
│   ├── token-rbac.yaml           <- binds a Role to the ServiceAccount
│   └── cert-rbac.yaml            <- binds a Role to the cert's GROUP
├── 01-serviceaccount-token/
│   ├── setup.sh   demo.sh   cleanup.sh
└── 02-client-certificate/
    ├── setup.sh   demo.sh   cleanup.sh
```

Run everything at once:

```bash
chmod +x run-all.sh cleanup-all.sh */*.sh
./run-all.sh
# ... explore ...
./cleanup-all.sh
```

Or step through each demo individually as described below.

---

## 4. Demo 1 — Token-based authentication (ServiceAccount)

**Idea:** A ServiceAccount is a *cluster-managed* identity. The API server mints
a short-lived JWT for it on demand. The client just carries that token.

### Steps

```bash
cd 01-serviceaccount-token
chmod +x *.sh
./setup.sh      # namespace + ServiceAccount + RBAC
./demo.sh       # mint token, build kubeconfig, test access
```

### What each step is doing

1. **`setup.sh`**
   - Creates namespace `auth-demo`.
   - Creates ServiceAccount `token-user`.
   - Applies `rbac/token-rbac.yaml` → a `Role` (read pods) + `RoleBinding` whose
     subject `kind` is **`ServiceAccount`**.
2. **`demo.sh`**
   - `kubectl create token token-user --duration=3600s` → mints a **short-lived
     JWT** via the **TokenRequest API**. (Since 1.24, SAs do *not* get a
     forever-Secret automatically — this is the secure default.)
   - Decodes the JWT's middle segment so you can *see* the claims (`sub`, `aud`,
     `exp`).
   - Writes `/tmp/token-user.kubeconfig` whose user block contains **only**
     `token:` — no cert, no key.
   - `kubectl auth whoami` → `system:serviceaccount:auth-demo:token-user`.
   - Proves the boundary: **can** list pods, **cannot** list secrets, **cannot**
     touch `kube-system`.

### The credential (excerpt of the generated kubeconfig)

```yaml
users:
- name: token-user
  user:
    token: eyJhbGciOiJSUzI1NiIs...   # <-- the whole identity is this string
```

### Key takeaways

- The token **expires** (here in 1 hour). After that the kubeconfig simply stops
  working — no revocation machinery needed.
- The cluster signs and can effectively *invalidate* tokens (delete the SA,
  rotate signing keys, or just wait for expiry).
- This is exactly how **pods** authenticate: the same JWT is auto-mounted at
  `/var/run/secrets/kubernetes.io/serviceaccount/token`.

---

## 5. Demo 2 — Certificate-based authentication (X.509 client cert)

**Idea:** *You* generate a keypair. The **cluster CA signs** your certificate.
Identity is baked into the certificate's subject and asserted during the TLS
handshake (mutual TLS).

- `Subject CN` → **username**
- `Subject O`  → **group(s)**

### Steps

```bash
cd 02-client-certificate
chmod +x *.sh
./setup.sh      # keygen + CSR + cluster signs it + RBAC
./demo.sh       # build kubeconfig, test access
```

### What each step is doing

1. **`setup.sh`**
   - `openssl genrsa` → a **private key** that *never leaves your machine*.
   - `openssl req -subj "/CN=cert-user/O=demo-readers"` → a **CSR** carrying the
     desired identity.
   - Submits a **`CertificateSigningRequest`** object with
     `signerName: kubernetes.io/kube-apiserver-client` and `usages: ["client auth"]`.
   - `kubectl certificate approve` → an **admin decision** (this is your access
     review moment).
   - Pulls the signed cert out of `.status.certificate`.
   - Applies `rbac/cert-rbac.yaml` → binds the Role to **`kind: Group`
     name: demo-readers**, so *any* cert with `O=demo-readers` inherits it.
2. **`demo.sh`**
   - Builds `/tmp/cert-user.kubeconfig` with `client-certificate-data` +
     `client-key-data` and **no token**.
   - `kubectl auth whoami` → `Username: cert-user`, `Groups: [demo-readers ...]`.
   - Proves the same RBAC boundary as Demo 1.

### The credential (excerpt of the generated kubeconfig)

```yaml
users:
- name: cert-user
  user:
    client-certificate-data: LS0tLS1CRUdJTi...   # signed by cluster CA
    client-key-data:         LS0tLS1CRUdJTi...   # your private key, base64
```

### ⚠️ The certificate gotcha you MUST teach

`kube-apiserver` **does not check a certificate revocation list (CRL)**. Once the
CA signs a cert, it is valid **until it expires** — you cannot cancel it. If a
cert-user's laptop is stolen, your only real options are:

- Remove their **authorization** (delete the RBAC binding) — they can still
  *authenticate*, but can't *do* anything.
- **Rotate the cluster CA** — invalidates *every* cert (very disruptive).

This is *the* reason to prefer short-lived certs and to prefer tokens/OIDC for
humans in most production setups.

### Fallback: direct CA signing (when the CSR API won't sign)

Some managed clusters don't run a signer for `kube-apiserver-client`. If
`setup.sh` reports the cert was never issued, sign directly with the CA keypair
(available on `minikube`/`kubeadm` nodes):

```bash
# minikube CA lives here:
CA_CRT=~/.minikube/ca.crt
CA_KEY=~/.minikube/ca.key
openssl x509 -req -in pki/cert-user.csr \
  -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out pki/cert-user.crt -days 1
# then run ./demo.sh as usual
```

---

## 6. Side-by-side comparison

| Dimension | Token (ServiceAccount / bearer) | Client certificate (X.509) |
|---|---|---|
| **Where identity lives** | Claims inside a signed JWT | `CN`/`O` inside the cert subject |
| **How it's presented** | HTTP header `Authorization: Bearer` | TLS handshake (mutual TLS) |
| **Who issues it** | Cluster (TokenRequest API) | Cluster CA signs your CSR |
| **Private key custody** | No client keypair; token is the secret | Client holds a private key (never shared) |
| **Expiry / rotation** | Built-in, short by default; easy to re-mint | You set validity; renewal = new CSR |
| **Revocation** | Effective (expiry, delete SA, rotate keys) | **Not supported** — valid until expiry |
| **Groups** | Fixed to the SA's identity | Arbitrary via `O` — flexible group mapping |
| **Best for** | Pods, CI/CD, controllers, automation | Bootstrap/break-glass admin, kubelets, air-gapped |
| **Human users?** | OK via OIDC tokens; SA tokens not ideal for people | Workable but hard to revoke — usually not preferred |
| **RBAC subject kind** | `ServiceAccount` | `User` (from CN) or `Group` (from O) |
| **Leak blast radius** | Bounded by short TTL | Large — valid until expiry, unrevocable |

---

## 7. When to choose what (decision guide)

Use this quick flow:

```
Is the client a workload running INSIDE the cluster
(pod, controller, operator, Job)?
        │ yes
        ▼
   ► Use a ServiceAccount TOKEN (auto-mounted, short-lived).  ✅ default

Is the client a CI/CD pipeline or external automation?
        │ yes
        ▼
   ► Use a scoped, short-lived TOKEN
     (projected SA token / TokenRequest, or a bound SA).       ✅

Is the client a HUMAN?
        │ yes
        ▼
   ► Prefer an OIDC / IdP-issued TOKEN (SSO, MFA, central revoke). ✅ best
     Client CERTS work but are hard to revoke — avoid for people
     unless you have automated short-lived cert issuance (e.g. SPIFFE,
     step-ca) or it's a break-glass path.

Is this cluster bootstrap, break-glass, or a core component
(kubelet, scheduler talking to apiserver) — possibly before any
token/OIDC infra exists?
        │ yes
        ▼
   ► Use CLIENT CERTIFICATES (no external dependency, works offline). ✅
```

### Rules of thumb

- **Default to tokens.** They expire, they're revocable in practice, and they're
  the native identity for everything running in-cluster.
- **Reach for certificates** when you need an identity that works with *zero
  external dependencies* — bootstrapping, air-gapped clusters, break-glass admin
  access, or Kubernetes' own control-plane components.
- **Humans → OIDC tokens** (Dex, Keycloak, Okta, Google, Azure AD). You get SSO,
  MFA, group sync, and *central* revocation — none of which raw certs give you.
- **Never hand a human a long-lived cert** unless you have automated short-lived
  issuance, precisely because you can't revoke it.
- **Both are useless without RBAC.** Authenticating as `cert-user` or
  `token-user` grants *nothing* until a RoleBinding says so — as both demos prove.

---

## 8. Cleanup

```bash
./cleanup-all.sh
# or per-demo:
#   01-serviceaccount-token/cleanup.sh
#   02-client-certificate/cleanup.sh
```

---

## 9. Try these to cement the learning

1. **Break authorization:** delete the RoleBinding and re-run `demo.sh`. Note the
   identity is still recognized (`auth whoami` works) but every action is
   `Forbidden`. → *Authentication ≠ authorization.*
2. **Expire a token:** mint a token with `--duration=60s`, wait, retry. Watch it
   fail cleanly. Now try the "revocation" equivalent for the cert — you can't.
3. **Change the group:** re-issue the cert with `O=demo-writers` and update RBAC
   to grant `create` on pods. See how `O` drives group-based access.
4. **Decode both credentials:** compare the JWT claims vs.
   `openssl x509 -text` on the cert. Same question ("who are you?"), two very
   different answers.
```
