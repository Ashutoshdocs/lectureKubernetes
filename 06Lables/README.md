# Kubernetes Labels & Selectors — Hands‑On Lab

Labels look like harmless metadata, but they're the connective tissue of a
Kubernetes cluster: Services find Pods, Deployments own Pods, and the scheduler
places Pods — all by matching labels. This lab teaches labels from "what is a
key/value pair" all the way to "how a Service silently leaks traffic when your
selector is too loose."

By the end you will be able to:

- Write valid labels and follow the community naming conventions.
- Query objects with **equality‑based** and **set‑based** selectors.
- Explain how Services and Deployments use selectors — and how they differ.
- Use labels to steer scheduling with `nodeSelector`.
- Add, change, and remove labels with `kubectl label`.
- Say when to reach for an **annotation** instead of a label.

---

## 1. What a label actually is

A label is a `key: value` pair in an object's `metadata.labels`. On its own it
does nothing — it's just a tag. The value appears when something **selects** on
it. Think of labels as the columns you'll later filter and join on.

```yaml
metadata:
  labels:
    app: nginx
    env: prod
    tier: frontend
```

Two jobs labels are built for:

1. **Identify & organize** — slice your objects by app, environment, team, etc.
2. **Wire things together** — Services, controllers, and scheduling all target
   objects *by label*, never by name.

---

## 2. The rules (so your labels don't get rejected)

**Keys** have an optional `prefix/` plus a name:

- Name: required, ≤ 63 chars, must start and end with a letter or digit; may
  contain `-`, `_`, `.` in the middle. e.g. `env`, `app.kubernetes.io/name`.
- Prefix: optional DNS subdomain ≤ 253 chars ending in `/`. `kubernetes.io/`
  and `k8s.io/` are **reserved** for the project — don't invent your own under
  them.

**Values**: ≤ 63 chars, may be empty; if non‑empty, start and end with a letter
or digit, with `-`, `_`, `.` allowed between. (So `1.27` is fine as a value, but
quote it in YAML — `"1.27"` — or it parses as a float.)

---

## 3. Naming conventions worth adopting

Ad‑hoc keys like `app`, `env`, `tier` (used in this lab for readability) are
fine. For anything shared across teams or tools, Kubernetes publishes a
**recommended set** under the `app.kubernetes.io/` prefix so tooling can rely on
them:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: nginx          # the app
    app.kubernetes.io/instance: nginx-prod # this deployment of it
    app.kubernetes.io/version: "1.27"      # version
    app.kubernetes.io/component: frontend  # role within the app
    app.kubernetes.io/part-of: storefront  # the larger system
    app.kubernetes.io/managed-by: helm     # what deploys it
```

Rule of thumb: keep labels **small, low‑cardinality, and meaningful to select
on**. A unique build‑ID per Pod is an annotation, not a label (see §9).

---

## 4. Selecting with `kubectl` — equality‑based

Equality selectors use `=`/`==` (identical) and `!=`. Commas mean **AND**.

```bash
kubectl get pods -l env=prod                 # nginx-prod, mysql-prod
kubectl get pods -l tier=frontend            # nginx-prod, nginx-staging
kubectl get pods -l app=nginx,env=prod       # AND -> nginx-prod only
kubectl get pods -l env!=prod                # nginx-staging
```

Handy display flags:

```bash
kubectl get pods --show-labels               # append a LABELS column
kubectl get pods -L app -L env -L tier       # each label as its own column
```

---

## 5. Selecting with `kubectl` — set‑based

Set selectors add `in`, `notin`, and existence checks. Quote them so your shell
leaves them alone.

```bash
kubectl get pods -l 'env in (prod,staging)'   # any nginx or mysql here
kubectl get pods -l 'tier notin (backend)'    # frontends only
kubectl get pods -l 'track'                    # Pods that HAVE a track label
kubectl get pods -l '!track'                   # Pods with NO track label (mysql)
kubectl get pods -l 'app=nginx,env in (prod)'  # mix equality + set, ANDed
```

`'track'` = *exists*; `'!track'` = *does not exist*. These have no
equality equivalent — they're the reason set‑based selectors exist.

---

## 6. How a Service uses labels (`02-nginx-service.yaml`)

A Service forwards traffic to whatever Pods match its `spec.selector` **right
now** — Pods can be created, deleted, or rescheduled and the Service keeps up,
because it tracks labels, not names.

```bash
kubectl apply -f 01-pods.yaml
kubectl apply -f 02-nginx-service.yaml
kubectl get endpoints nginx-prod-svc     # -> only nginx-prod's Pod IP
```

A Service selector is **equality‑only** and every entry is ANDed. Our selector
is `app=nginx, env=prod, tier=frontend`, so it grabs `nginx-prod` and skips
`nginx-staging`.

**The teaching trap:** delete the `env: prod` line, re‑apply, and re‑check the
endpoints — now *both* nginx Pods are listed and production traffic can hit a
staging Pod. This is the single most common labelling bug, and it's why `env`
belongs in your labels and selectors, not just in the Pod's name.

---

## 7. How a Deployment uses labels (`03-nginx-deployment.yaml`)

Controllers own the Pods matching their selector. Their selector is richer than
a Service's — it supports `matchLabels` (equality map) **and**
`matchExpressions` (set‑based), ANDed together:

```yaml
selector:
  matchLabels:
    app: nginx
    tier: frontend
  matchExpressions:
    - {key: env, operator: In, values: ["prod"]}
```

Operators: `In`, `NotIn`, `Exists`, `DoesNotExist`.

Two rules that bite beginners:

- **Template must match selector.** The Pods a Deployment stamps out
  (`spec.template.metadata.labels`) have to satisfy the selector, or the object
  is rejected. Extra labels beyond the selector are fine.
- **Selector is immutable.** Once created you can't re‑point `spec.selector` at
  a different label set — you delete and recreate.

```bash
kubectl apply -f 03-nginx-deployment.yaml
kubectl get pods -l app=nginx,env=prod --show-labels   # 3 Pods, all tagged
kubectl get rs -l app=nginx                            # the ReplicaSet it made
```

---

## 8. Labels on nodes → scheduling (`04-nodeselector-pod.yaml`)

Nodes are labelled too. A Pod's `nodeSelector` restricts it to matching nodes —
the simplest form of label‑driven scheduling.

```bash
kubectl get nodes --show-labels
kubectl label nodes <node-name> disktype=ssd
kubectl apply -f 04-nodeselector-pod.yaml
kubectl get pod ssd-pod -o wide          # scheduled onto the labelled node
```

If no node carries `disktype=ssd`, `ssd-pod` stays `Pending` — proof the label
is what's steering placement. For "prefer but don't require", multiple options,
or negation, graduate to **nodeAffinity**, which uses the same label vocabulary
with more expressive rules.

---

## 9. Managing labels imperatively with `kubectl label`

You don't have to edit YAML to change labels:

```bash
kubectl label pod nginx-prod team=payments          # add
kubectl label pod nginx-prod team=platform --overwrite   # change existing
kubectl label pod nginx-prod team-                  # remove (trailing dash)
kubectl label pods --all reviewed=true              # bulk add to every Pod
kubectl label pods -l env=prod audited=2025 --overwrite   # add to a selection
```

Great for quick triage, but remember: changes made this way drift from your
manifests. Fold anything permanent back into the YAML.

---

## 10. Labels vs Annotations — pick the right tool

| | Labels | Annotations |
|---|---|---|
| Purpose | **Identify & select** | Attach arbitrary metadata |
| Selectable? | Yes (`-l`, selectors) | No |
| Size/shape | Short, ≤ 63‑char values | Can be large, structured (JSON, URLs, notes) |
| Good for | app, env, tier, version, team | build hash, git commit, contact, change‑cause, tool config |

If you'll ever *query or route* on it, it's a label. If it's just information
for humans or tools to read, it's an annotation.

---

## 11. Gotchas & troubleshooting

- **Service has no endpoints.** The selector matches no Pods, or the Pods'
  labels don't match. `kubectl get pods -l <your-selector>` should list them.
- **Selector too loose.** `{app: nginx}` alone spans environments — always
  scope Services and Deployments with `env`/`tier` as needed.
- **Deployment rejected: "selector does not match template labels".** Make the
  template labels a superset of the selector.
- **Set selectors "not working" in the shell.** Quote them:
  `-l 'env in (prod,staging)'`, not `-l env in (prod,staging)`.
- **YAML turned `1.27` into `1.27`‑the‑float.** Quote numeric‑looking values.
- **Can't change a Deployment's selector.** It's immutable; recreate the object.

---

## 12. Clean up

```bash
kubectl delete -f 04-nodeselector-pod.yaml --ignore-not-found
kubectl delete -f 03-nginx-deployment.yaml --ignore-not-found
kubectl delete -f 02-nginx-service.yaml    --ignore-not-found
kubectl delete -f 01-pods.yaml             --ignore-not-found

kubectl label nodes <node-name> disktype-      # remove the node label

# or sweep everything (Pods carry app=nginx / app=mysql):
kubectl delete pods,svc,deploy -l app=nginx
kubectl delete pods -l app=mysql
```

---

## Housekeeping note

`01-pods.yaml` hardcodes the MySQL root password to keep the lab focused on
labels. In anything real, put it in a `Secret` and reference it with
`valueFrom.secretKeyRef` — never commit a password to a manifest.

---

### One‑line summary to leave students with

> Labels are the keys everything joins on: Services route by them, controllers
> own Pods by them, and the scheduler places Pods by them — so choose a small,
> consistent set and keep your selectors tight enough to not cross environments.
