# Kubernetes ConfigMaps & Secrets — Hands‑On Lab

Configuration and credentials don't belong baked into an image — they belong in
**ConfigMaps** (non‑secret settings) and **Secrets** (sensitive values), injected
at runtime. This lab runs MySQL in dev and prod, showing every way to inject
config, and treating the Secret security story honestly (spoiler: base64 is not
encryption).

By the end you will be able to:

- Choose between a ConfigMap and a Secret, and between `data` and `stringData`.
- Inject config four different ways and know when to use each.
- Predict whether a config change reaches a running Pod (env vs volume).
- Lock config with `immutable: true`.
- Explain what a Secret actually protects you from — and harden it properly.

---

## 1. ConfigMap vs Secret

Both are namespaced key/value stores consumed the same ways. The differences:

| | ConfigMap | Secret |
|---|---|---|
| For | non‑confidential config | sensitive values (passwords, tokens, keys) |
| Stored as | plain text | base64 (see the warning below) |
| Volume backing on node | regular file | **tmpfs (RAM)**, not written to disk |
| Extra protections | none special | encryption‑at‑rest option, tighter RBAC by convention |
| Size limit | 1 MiB | 1 MiB |

> **base64 ≠ encryption.** A Secret's values are only base64‑encoded in the
> stored object. Anyone who can `get` the Secret, or read etcd, can decode them
> in one command. A Secret is protected by your **RBAC** and by **encryption at
> rest**, not by the encoding. Treat §9 as the real lesson here.

`data` vs `stringData`: in a Secret, `stringData` lets you write the plain value
and Kubernetes base64‑encodes it for you; `data` expects you to pre‑encode. After
apply, both appear under `data`. ConfigMaps just use `data` (plain).

---

## 2. The four ways to inject config

| Method | Looks like | Best for |
|---|---|---|
| Single env var | `env: [{valueFrom: {configMapKeyRef/secretKeyRef}}]` | one or two specific keys |
| Bulk env vars | `envFrom: [{configMapRef/secretRef}]` | importing a whole ConfigMap/Secret |
| File(s) via volume | `volumes: [{configMap/secret}]` + `volumeMounts` | config files, certs, passwords |
| Command arg | `args: ["--flag=$(MY_ENV)"]` | passing an injected env into the command |

`03-mysql-dev.yaml` uses the first three at once so you can compare them.

---

## 3. Files

| File | What it teaches |
|---|---|
| `00-namespaces.yaml` | dev + prod namespaces |
| `01-configmap-dev.yaml` | scalar keys (for env) vs a file key (for volume) |
| `02-secret-dev.yaml` | `stringData`, `type: Opaque`, base64 reality |
| `03-mysql-dev.yaml` | all injection methods in one Pod |
| `04-configmap-prod.yaml` | `immutable: true` |
| `05-secret-prod.yaml` | immutable Secret keyed for file mounting |
| `06-mysql-prod.yaml` | hardened: secrets as **files**, `_FILE` convention, resources |

---

## 4. Apply

```bash
kubectl apply -f 00-namespaces.yaml
kubectl apply -f 01-configmap-dev.yaml -f 02-secret-dev.yaml -f 03-mysql-dev.yaml
kubectl apply -f 04-configmap-prod.yaml -f 05-secret-prod.yaml -f 06-mysql-prod.yaml

kubectl get cm,secret,deploy -n dev
kubectl get cm,secret,deploy -n prod
```

---

## 5. Verify the config actually landed (dev)

```bash
# Methods 1 & 2 - env vars from ConfigMap and Secret:
kubectl exec -n dev deploy/mysql -- env | grep -E 'MYSQL|TZ'

# Method 3 - the ConfigMap key mounted as a file:
kubectl exec -n dev deploy/mysql -- cat /etc/mysql/conf.d/my.cnf

# Decode a Secret yourself, to feel how thin base64 is:
kubectl get secret mysql-secret -n dev \
  -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d ; echo
```

End‑to‑end proof the values are wired correctly — the DB named in the ConfigMap
exists, using the password from the Secret:

```bash
kubectl exec -it -n dev deploy/mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "show databases;"'   # lists devdb
```

---

## 6. Verify the hardened prod pattern

```bash
# Passwords are FILES on an in-memory tmpfs, not env vars:
kubectl exec -n prod deploy/mysql -- ls -l /etc/mysql/secrets
kubectl exec -n prod deploy/mysql -- mount | grep /etc/mysql/secrets   # tmpfs

# The env holds only the PATH, never the password itself:
kubectl exec -n prod deploy/mysql -- env | grep MYSQL

# It still works, because the MySQL image reads MYSQL_ROOT_PASSWORD_FILE:
kubectl exec -it -n prod deploy/mysql -- \
  sh -c 'mysql -uroot -p"$(cat /etc/mysql/secrets/root-password)" -e "show databases;"'  # proddb
```

---

## 7. How updates propagate (a crucial, non‑obvious rule)

This trips up almost everyone. Update behaviour depends on how you consumed it:

| Consumed as | Does a live Pod see the change? |
|---|---|
| `env` / `envFrom` | **No** — env is fixed at container start; needs a restart |
| Volume mount | **Yes** — kubelet refreshes the file (eventually, ~1 min) |
| Volume mount with `subPath` | **No** — subPath files are not updated |
| Anything `immutable: true` | **No** — the object can't change at all |

Watch it happen (dev, non‑immutable):

```bash
kubectl edit configmap mysql-cnf -n dev        # change max_connections=200
# wait ~60s, then:
kubectl exec -n dev deploy/mysql -- cat /etc/mysql/conf.d/my.cnf   # file updated

# But an env-injected value stays stale until you restart:
kubectl edit configmap mysql-config -n dev     # change TZ
kubectl exec -n dev deploy/mysql -- printenv TZ   # unchanged
kubectl rollout restart deployment/mysql -n dev   # now it picks up the new value
```

> Even when a mounted file updates, your app only benefits if it *re‑reads* the
> file. MySQL won't re‑read my.cnf without a restart — so config changes to a
> running app usually still mean a `rollout restart`.

---

## 8. Immutable config (prod)

```bash
kubectl edit configmap mysql-config -n prod    # rejected: field is immutable
```

To change immutable config you delete and recreate it, then roll the Deployment.
That friction is the point for production credentials and settings.

---

## 9. Secret security — the part that actually matters

A Secret out of the box gives you *organisational* separation, not secrecy. Do
these to make it real:

- **Encrypt etcd at rest.** Configure an `EncryptionConfiguration`
  (aescbc or, better, a KMS provider). Without it, Secrets sit in etcd as plain
  base64.
- **Lock down RBAC.** `get`/`list` on Secrets is effectively "read the
  passwords." Grant it narrowly, per namespace.
- **Prefer file mounts over env vars** for the most sensitive values (as prod
  does) — env is far easier to leak.
- **Never commit real Secrets to Git.** Manifests like `02-secret-dev.yaml` are
  fine for a lab, not for a repo. Use sealed‑secrets, External Secrets Operator,
  SOPS, or a real secret manager (Vault, cloud KMS) and inject at deploy time.
- **Rotate.** Immutable Secrets + `rollout restart` make rotation a clean,
  auditable operation.
- **Scope tightly.** Secrets are namespaced; a Pod can only mount Secrets from
  its own namespace, so don't share one Secret across environments.

---

## 10. dev vs prod — the hardening diff at a glance

| | dev (`03`) | prod (`06`) |
|---|---|---|
| Secrets delivered as | env vars | **files on tmpfs** |
| Password value in env | yes | no — only a `*_FILE` path |
| ConfigMap/Secret | mutable | **immutable** |
| Resources | none | requests + limits |

Same app, two postures: dev optimised for "see how it works," prod for "don't
leak the password."

---

## 11. Gotchas & troubleshooting

- **Pod stuck `CreateContainerConfigError`.** A referenced ConfigMap/Secret key
  doesn't exist (or the object isn't in the same namespace).
  `kubectl describe pod` names the missing key. Add `optional: true` to a ref if
  it's genuinely optional.
- **`envFrom` skipped a key.** The key isn't a valid env‑var name (e.g. contains
  `.` or `-`). Move file‑style content to its own ConfigMap and mount it.
- **Changed a ConfigMap, nothing happened.** It was consumed via env — restart
  the Pod (`kubectl rollout restart`).
- **Can't edit a ConfigMap/Secret.** It's `immutable: true`; delete & recreate.
- **MySQL won't start with file‑mounted secret.** Use the `_FILE` env vars
  (`MYSQL_ROOT_PASSWORD_FILE`), not the plain ones, and check the mount path.
- **Cross‑namespace reference fails.** ConfigMaps/Secrets are namespaced; a Pod
  can only use ones in its own namespace.

---

## 12. Clean up

```bash
kubectl delete namespace dev prod        # removes everything inside both
```

---

## Housekeeping note

Both Secrets store their passwords in plaintext `stringData` so the lab is
self‑contained. In anything real, keep credentials out of your manifests
entirely (see §9) — a password committed to version control is compromised.

---

### One‑line summary to leave students with

> Put settings in ConfigMaps and sensitive values in Secrets, inject them as env
> vars or files, and remember two things: a config change only reaches a running
> Pod through a **volume mount** (env needs a restart), and a Secret is only as
> safe as your **RBAC and encryption at rest** — the base64 is not protecting
> anything.
