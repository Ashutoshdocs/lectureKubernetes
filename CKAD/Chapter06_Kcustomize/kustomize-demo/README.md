# Kustomize End-to-End Lab — Student App

Deploy **one application** into **three environments** (dev, staging, prod) without ever editing the original YAML.

By the end, students can explain and use: bases, overlays, namespaces, name prefixes/suffixes, labels and annotations, replica and image overrides, ConfigMap and Secret generators (with hash-based rollouts), three kinds of patches, and reusable **components**.

| | |
|---|---|
| **Duration** | ~2.5 hours (10 modules, 10–20 min each) |
| **Level** | Knows `kubectl apply`, Deployments and Services |
| **Needs** | A cluster (kind, minikube, Docker Desktop) and `kubectl` ≥ 1.27 |

---

## Project layout

```
kustomize-demo/
├── base/                         # Shared truth — overlays never edit this
│   ├── deployment.yaml           # nginx, probes, resources, envFrom, html volume
│   ├── service.yaml
│   ├── html/index.html           # grey "BASE" page
│   └── kustomization.yaml        # labels + ConfigMap/Secret generators
│
├── components/                   # Reusable, opt-in features
│   ├── hpa/                      # HorizontalPodAutoscaler
│   ├── pdb/                      # PodDisruptionBudget
│   └── monitoring/               # Patch: Prometheus scrape annotations
│
├── overlays/
│   ├── dev/                      # 1 replica, debug logs, green page
│   ├── staging/                  # nameSuffix, registry mirror, HPA, orange page
│   └── prod/                     # pinned image, HPA+PDB+monitoring, 3 patch styles, red page
│       ├── patches/
│       │   ├── resources.yaml            # strategic merge patch
│       │   └── add-env.json6902.yaml     # JSON 6902 patch
│       ├── secrets.env.example           # copy to secrets.env (git-ignored)
│       └── kustomization.yaml
│
├── scripts/
│   ├── validate.sh               # build every overlay (CI-friendly)
│   └── compare-envs.sh           # diff two rendered environments
├── Makefile                      # make build|diff|apply|status|open|delete ENV=dev
└── .gitignore
```

**What students see:** each environment serves a different coloured web page, so the effect of an overlay is visible in the browser, not just in YAML.

| Env | Namespace | Names | Replicas | Image | Extras | Page |
|---|---|---|---|---|---|---|
| dev | `student-dev` | `dev-*` | 1 | `nginx:1.27-alpine` | debug logs | 🟢 green |
| staging | `student-staging` | `stg-*-v2` | 2 → HPA | `public.ecr.aws/nginx/nginx:1.27-alpine` | HPA | 🟠 orange |
| prod | `student-prod` | `prod-*` | 3 → HPA | `nginx:1.27.3-alpine` | HPA, PDB, monitoring, patches, NodePort | 🔴 red |

---

## Module 0 — Setup (10 min)

```bash
kubectl version --client          # Kustomize is built in: kubectl kustomize / apply -k
kubectl cluster-info

# Optional: standalone binary (newer features, faster)
kustomize version

# Local cluster if you don't have one
kind create cluster --name kustomize-lab

# Prod reads its secret from a git-ignored file
cp overlays/prod/secrets.env.example overlays/prod/secrets.env
```

> **Teaching note:** `kubectl kustomize` bundles a specific Kustomize version. Run `kubectl version --client -o yaml` to see it. This lab works with Kustomize v5+ (kubectl 1.27+).

---

## Module 1 — The base (15 min)

**Goal:** understand that a base is plain, valid Kubernetes YAML plus a `kustomization.yaml` that lists it.

```bash
cat base/kustomization.yaml
kubectl kustomize base
```

**Observe:**

- `student-config-<hash>`, `student-html-<hash>` and `student-secret-<hash>` were **generated** — they don't exist as files.
- The Deployment's `envFrom` and `volumes` now point at the **hashed** names. Kustomize rewrote the references for you.
- `app.kubernetes.io/name` and `part-of` appear on every object **and** inside the Deployment/Service selectors (`includeSelectors: true`).

> **Teaching note — why hashes matter:** change `LOG_LEVEL=info` to `LOG_LEVEL=error` in `base/kustomization.yaml` and re-run the build. The ConfigMap name changes → the Deployment spec changes → pods roll automatically. Without the hash, a ConfigMap edit leaves running pods on stale config. Revert the change afterwards.

---

## Module 2 — Dev overlay: namespace, prefix, replicas (15 min)

```bash
cat overlays/dev/kustomization.yaml
kubectl kustomize overlays/dev
```

**Observe:**

| Field | Base | Dev |
|---|---|---|
| Deployment name | `student-app` | `dev-student-app` |
| Namespace | *(none)* | `student-dev` |
| Replicas | 2 | 1 |
| `APP_ENV` | base | dev |
| Labels | — | `environment: development`, `owner: devops` |

Show the full diff in one command:

```bash
./scripts/compare-envs.sh base dev
```

> **Teaching note:** `replicas:` uses the **base** name (`student-app`), not `dev-student-app`. Transformers like `namePrefix` run *last*, after replicas, images and patches have matched.

---

## Module 3 — Deploy and verify dev (15 min)

```bash
kubectl diff -k overlays/dev        # preview cluster changes (empty namespace → all new)
kubectl apply -k overlays/dev       # namespace.yaml is in the overlay — no manual create
kubectl -n student-dev rollout status deploy/dev-student-app

kubectl -n student-dev get all,cm,secret --show-labels
kubectl -n student-dev describe deploy dev-student-app

# See it in the browser → http://localhost:8080 (green page)
kubectl -n student-dev port-forward svc/dev-student-service 8080:80
```

Check config reached the container:

```bash
kubectl -n student-dev exec deploy/dev-student-app -- env | grep -E 'APP_ENV|LOG_LEVEL|DB_'
```

Shortcut for every step above: `make apply ENV=dev && make status ENV=dev && make open ENV=dev`.

---

## Module 4 — Generators in depth: merge vs replace (15 min)

Dev's `kustomization.yaml` shows both behaviours:

```yaml
configMapGenerator:
  - name: student-config
    behavior: merge       # keep COURSE, TRAINER; override APP_ENV, LOG_LEVEL
  - name: student-html
    behavior: replace     # throw away the base page entirely
```

**Live demo — trigger a rollout from a config change:**

```bash
kubectl -n student-dev get rs                    # note the ReplicaSet
# edit overlays/dev/kustomization.yaml → LOG_LEVEL=trace
kubectl apply -k overlays/dev
kubectl -n student-dev get rs                    # a NEW ReplicaSet appeared
kubectl -n student-dev get cm                    # old + new ConfigMap side by side
```

> **Teaching note:** the old ConfigMap is left behind. Clean up with `kubectl apply -k ... --prune -l app.kubernetes.io/part-of=kustomize-demo` or let your GitOps tool (Argo CD / Flux) prune it.

**Secrets:** base generates placeholders; dev replaces them with literals; prod reads `secrets.env`.

```bash
kubectl -n student-dev get secret -o name
kubectl -n student-dev get secret <name> -o jsonpath='{.data.DB_USER}' | base64 -d; echo
```

> **Security note:** generated Secrets are only base64-encoded. Real projects use Sealed Secrets, SOPS (KSOPS plugin) or External Secrets Operator. Never commit `secrets.env` — it's in `.gitignore`.

---

## Module 5 — Staging: suffix, image mirror, first component (15 min)

```bash
cat overlays/staging/kustomization.yaml
kubectl kustomize overlays/staging | grep -E '^  name:|image:'
```

**Observe:**

- `nameSuffix: -v2` → `stg-student-app-v2`. Note the hash still goes **after** the suffix: `stg-student-config-v2-<hash>`.
- `images.newName` swaps the registry (`public.ecr.aws/nginx/nginx`) — common for air-gapped clusters or internal mirrors.
- `components: [../../components/hpa]` adds an HPA, and its `scaleTargetRef` was renamed to `stg-student-app-v2` automatically. Kustomize knows which fields hold names of other objects.

```bash
kubectl apply -k overlays/staging
kubectl -n student-staging get hpa
```

> **Teaching note:** HPA needs metrics-server to show CPU %. On kind: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml` then patch it with `--kubelet-insecure-tls`. Without it the HPA shows `<unknown>` — that's fine for this lab.

---

## Module 6 — Components vs bases (10 min)

| | Base (`resources:`) | Component (`components:`) |
|---|---|---|
| `kind` | `Kustomization` | `Component` |
| Purpose | The thing you deploy | An optional feature you mix in |
| Can patch the parent? | No | **Yes** (see `components/monitoring`) |
| Typical examples | app, database | HPA, PDB, monitoring, TLS, debug sidecar |

Without components you'd copy the HPA into every overlay that needs it, or build a "base-with-hpa" — both drift over time.

**Exercise:** add monitoring to dev by adding one line, then build:

```yaml
components:
  - ../../components/monitoring
```

---

## Module 7 — Prod: the three patch styles (20 min)

```bash
cat overlays/prod/kustomization.yaml
kubectl kustomize overlays/prod > /tmp/prod.yaml
```

| Style | File | Best for | Look for in output |
|---|---|---|---|
| **Strategic merge** | `patches/resources.yaml` | Changing nested fields; lists merge by key (containers by `name`) | Higher CPU/memory, `RollingUpdate` with `maxUnavailable: 0` |
| **JSON 6902** | `patches/add-env.json6902.yaml` | Exact operations: add/remove/replace a path | `FEATURE_FLAGS` env, `terminationGracePeriodSeconds: 45` |
| **Inline + target** | inside `kustomization.yaml` | Small one-off changes, or one patch for many matching objects | Service `type: NodePort` |

```bash
grep -A3 'resources:' /tmp/prod.yaml
grep -A2 FEATURE_FLAGS /tmp/prod.yaml
grep 'type:' /tmp/prod.yaml
```

> **Common mistake (from the old practical):** naming the patch target `prod-student-app`. Patches match the **pre-prefix** name, so use `student-app`.

> **Teaching note — `target` selectors** can match many objects at once, e.g. every Deployment with a label:
> ```yaml
> - target: { kind: Deployment, labelSelector: "app=student" }
>   patch: ...
> ```

---

## Module 8 — Deploy prod and compare environments (15 min)

```bash
kubectl diff -k overlays/prod
kubectl apply -k overlays/prod
kubectl -n student-prod get deploy,hpa,pdb,svc
kubectl -n student-prod get deploy prod-student-app -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

./scripts/compare-envs.sh dev prod | less
```

Open the red page: `make open ENV=prod`.

> **Teaching note — replicas vs HPA:** prod sets `replicas: 3` but the HPA has `minReplicas: 2`. Once the HPA is active, it owns the replica count. In GitOps setups many teams remove `spec.replicas` from the Deployment when an HPA manages it, so every `apply` doesn't fight the autoscaler.

---

## Module 9 — Labels, annotations and the selector trap (10 min)

```bash
kubectl get deploy -A -l app.kubernetes.io/part-of=kustomize-demo --show-labels
kubectl -n student-prod get deploy prod-student-app -o jsonpath='{.metadata.annotations}'; echo
```

The rule used throughout this lab:

| Where | Setting | Why |
|---|---|---|
| Base | `includeSelectors: true` | Stable identity labels, set once, go into selectors |
| Overlays | `includeSelectors: false` | Environment labels change freely without touching selectors |

**Why:** Deployment selectors are **immutable**. If an overlay adds a label to the selector and you later change it, `kubectl apply` fails with `field is immutable` and you must delete and recreate the Deployment. The old `commonLabels` field always wrote into selectors, which is why it's deprecated in favour of `labels`.

**Demo the failure (optional):** in `overlays/dev` set `includeSelectors: true`, apply, change `owner: devops` to `owner: platform`, apply again → error. Revert.

---

## Module 10 — CI checks and cleanup (10 min)

```bash
make validate                  # builds every overlay; add kubeconform for schema checks
make build-all                 # writes rendered/<env>.yaml — what GitOps tools apply
```

A minimal CI job is just `./scripts/validate.sh`: if anyone breaks an overlay, the pipeline fails before it reaches a cluster.

**Cleanup:**

```bash
make delete-all                # deletes each overlay, including its namespace
kind delete cluster --name kustomize-lab
```

---

## Hands-on exercises

<details><summary><b>1.</b> Add <code>qa</code> environment: namespace <code>student-qa</code>, prefix <code>qa-</code>, 2 replicas, purple page, PDB component.</summary>

```bash
cp -r overlays/dev overlays/qa
# edit namespace.yaml → student-qa; kustomization.yaml → namespace, namePrefix, replicas, labels, APP_ENV
# add: components: [../../components/pdb]
# change the colour in overlays/qa/html/index.html
kubectl kustomize overlays/qa
```
</details>

<details><summary><b>2.</b> In prod, pin the image by digest instead of tag.</summary>

```yaml
images:
  - name: nginx
    digest: sha256:<digest-from-registry>
```
Digests are immutable; tags can be re-pushed.
</details>

<details><summary><b>3.</b> Remove the liveness probe in dev only, using a JSON 6902 patch.</summary>

```yaml
patches:
  - target: { kind: Deployment, name: student-app }
    patch: |-
      - op: remove
        path: /spec/template/spec/containers/0/livenessProbe
```
</details>

<details><summary><b>4.</b> Load config from a file instead of literals.</summary>

Create `overlays/dev/app.properties`, then:
```yaml
configMapGenerator:
  - name: student-config
    behavior: merge
    envs: [app.properties]     # each KEY=VALUE line becomes a key
```
Use `files:` instead of `envs:` to store the whole file as one key.
</details>

<details><summary><b>5.</b> Turn off the hash suffix for one ConfigMap. When would you want this?</summary>

```yaml
generatorOptions:
  disableNameSuffixHash: true
```
Only when something outside Kustomize references the ConfigMap by a fixed name. You lose automatic rollouts on change.
</details>

<details><summary><b>6.</b> Create a <code>debug</code> component that adds a busybox sidecar and use it in dev.</summary>

```yaml
# components/debug/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - target: { kind: Deployment }
    patch: |-
      - op: add
        path: /spec/template/spec/containers/-
        value: { name: debug, image: busybox:1.36, command: ["sleep", "infinity"] }
```
</details>

---

## Kustomize vs Helm

| | Kustomize | Helm |
|---|---|---|
| Approach | Patch plain YAML (overlay) | Template YAML with `{{ }}` values |
| Learning curve | Low — it's just YAML | Higher — Go templates, functions |
| Packaging / sharing | Git directories, remote bases | Charts in repositories, versioned |
| Release tracking / rollback | None (use Git / GitOps) | Built in (`helm rollback`) |
| Logic (if/loops) | None by design | Full templating logic |
| Best for | Your own apps across environments | Distributing apps to many users |

They combine well: `helmCharts:` in a kustomization (`kustomize build --enable-helm`), or patching a rendered Helm chart with a Kustomize overlay. Argo CD and Flux support both natively.

---

## Interview questions — quick answers

1. **What is Kustomize?** A template-free tool to customise Kubernetes YAML through layered overlays; built into `kubectl` (`-k`).
2. **Base vs overlay?** Base = shared manifests; overlay = environment-specific changes referencing the base.
3. **What is a component?** A reusable, opt-in bundle of resources/patches (`kind: Component`) that overlays include via `components:`.
4. **namePrefix / nameSuffix?** Add text to every object name and update all references to them.
5. **Why does a generated ConfigMap get a hash?** So a content change creates a new name, which changes the pod spec and triggers a rollout.
6. **merge vs replace behaviour?** `merge` keeps base keys and overrides listed ones; `replace` discards base content.
7. **How do you override images?** `images:` with `newName`, `newTag` or `digest`, matched by the image name in the base.
8. **Strategic merge vs JSON 6902?** SMP is a partial object merged by keys; JSON 6902 is explicit operations on paths (good for removals and list indexes).
9. **Why is `commonLabels` deprecated?** It always modified selectors, which are immutable; `labels` lets you choose with `includeSelectors`.
10. **`kubectl kustomize` vs `kubectl apply -k`?** The first renders to stdout; the second renders and applies.
11. **How do you preview changes?** `kubectl diff -k <dir>`.
12. **How do you handle secrets safely?** Keep values out of Git (`.env` ignored), or use SOPS / Sealed Secrets / External Secrets.
13. **Why must patches use the base name?** Patches are matched before name transformers run.
14. **How do you remove stale generated ConfigMaps?** `apply --prune` with a label selector, or GitOps pruning.
15. **Kustomize or Helm?** Kustomize for your own multi-environment apps; Helm for packaged, distributable, versioned releases.

---

## What changed from the original practical

| Original | Upgraded | Why |
|---|---|---|
| `commonLabels` | `labels` with `includeSelectors` | `commonLabels` is deprecated and breaks immutable selectors |
| `kubectl create namespace` by hand | `namespace.yaml` in each overlay | One command deploys everything; deletes clean up fully |
| Plain-text password in base | Placeholder in base, `secrets.env` (git-ignored) in prod | Never commit credentials |
| Requirement said `nginx:latest`, YAML used `1.25` | Pinned tag in prod; mirror registry in staging | Consistent, reproducible images |
| Patch section replaced the whole prod overlay | All features coexist in one working prod overlay | Students see the full picture |
| 2 environments | 3 environments + reusable components | Shows real reuse and opt-in features |
| No visible output | Colour-coded page per environment | Immediate feedback in the browser |
| No probes or resources | Probes, requests/limits, rollout strategy, HPA, PDB | Production-grade baseline |
| No automation | Makefile, `validate.sh`, `compare-envs.sh` | Faster demos; CI-ready |
