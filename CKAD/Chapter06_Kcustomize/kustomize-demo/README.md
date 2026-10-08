<div align="center">

# ☸️ Kustomize End-to-End Practical

### One base. Two overlays. Three live web pages that prove it.

![kubectl](https://img.shields.io/badge/kubectl-built--in%20kustomize-326CE5?logo=kubernetes&logoColor=white)
![Kustomize](https://img.shields.io/badge/kustomize-v5-326CE5)
![nginx](https://img.shields.io/badge/nginx-alpine-009639?logo=nginx&logoColor=white)
![Services](https://img.shields.io/badge/Services-NodePort-orange)

</div>

---

## 🎯 Objective

Deploy the **same** application into **BASE**, **DEV** and **PROD** without editing the original YAML.
Each environment is exposed on its **own NodePort** and serves the **same HTML page**, which reads live
values from its pod and shows, row by row, **what came from base and what the overlay changed**.

| Environment | Command | Namespace | NodePort | Replicas | Image | Page colour |
|---|---|---|---|---|---|---|
| **BASE** | `kubectl apply -k base -n base` | `base` | **30080** | 1 | `nginx:1.25-alpine` | ⚪ slate |
| **DEV** | `kubectl apply -k overlays/dev` | `dev` | **30081** | 1 | `nginx:1.25-alpine` | 🔵 blue |
| **PROD** | `kubectl apply -k overlays/prod` | `prod` | **30082** | 3 | `nginx:1.27-alpine` | 🟢 green |

> 💡 **The proof:** `index.html` exists **only** in `base/html/`. Dev and prod never copy it, yet each
> page looks different. Every difference comes from Kustomize transforming the manifests.

---

## 🧭 How it works

```text
                     ┌──────────────────────────────────────────┐
                     │                 base/                     │
                     │  deployment.yaml   service.yaml (30080)   │
                     │  html/index.html   nginx/*.template       │
                     │  configMapGenerator · secretGenerator     │
                     └───────────────┬──────────────────────────┘
                                     │  resources: - ../../base
                   ┌─────────────────┴─────────────────┐
                   ▼                                   ▼
     ┌───────────────────────────┐       ┌───────────────────────────┐
     │      overlays/dev         │       │      overlays/prod        │
     │  namespace: dev           │       │  namespace: prod          │
     │  namePrefix: dev-         │       │  namePrefix: prod-        │
     │  replicas: 1              │       │  replicas: 3              │
     │  label env=development    │       │  label env=production     │
     │  ConfigMap merge (blue)   │       │  images: newTag 1.27      │
     │  JSON patch → 30081       │       │  SMP patch → bigger limits│
     │                           │       │  JSON patch → 30082       │
     └─────────────┬─────────────┘       └─────────────┬─────────────┘
                   ▼                                   ▼
          http://<node>:30081                 http://<node>:30082
```

**How the page knows** — every value on screen is real, read inside the pod:

| On the page | Where it comes from | Changed by |
|---|---|---|
| Namespace, pod name, node, IP | Downward API `fieldRef` | `namespace:`, `namePrefix:` |
| `environment` label | Downward API `metadata.labels` | `labels:` |
| Layer annotation | Downward API `metadata.annotations` | `commonAnnotations:` |
| CPU / memory limits | Downward API `resourceFieldRef` | strategic-merge patch |
| nginx version | nginx's own `$nginx_version` | `images:` |
| Colour & message | `configMapGenerator` → env | `behavior: merge` |
| Secret username | `secretGenerator` → env | (inherited from base) |
| NodePort | browser URL port | JSON6902 patch |

nginx serves these as JSON on `/info`; `index.html` compares them with the base defaults and badges each
row **from base** 🟩 or **overlay** 🟧.

---

## 📁 Project structure

```text
kustomize-demo/
├── README.md
├── base/
│   ├── kustomization.yaml          # resources, labels, annotations, generators
│   ├── deployment.yaml             # nginx + Downward API env vars
│   ├── service.yaml                # NodePort 30080
│   ├── html/
│   │   └── index.html              # the ONE page (→ ConfigMap student-html)
│   └── nginx/
│       └── default.conf.template   # serves / , /info , /healthz
└── overlays/
    ├── dev/
    │   └── kustomization.yaml      # ns, prefix, 1 replica, merge, port 30081
    └── prod/
        ├── kustomization.yaml      # ns, prefix, 3 replicas, image, port 30082
        └── resources-patch.yaml    # strategic-merge patch: bigger limits
```

---

## ✅ Step 0 — Installation check

```bash
kubectl version --client
kubectl kustomize --help
# optional standalone binary
kustomize version
```

Any cluster with reachable node ports works: **minikube**, **kind** (map ports 30080-30082), **k3s**, or a cloud VM.

---

## 🧱 Step 1 — The base

### `base/deployment.yaml` (key parts)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: student-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: student
  template:
    metadata:
      labels:
        app: student
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine          # prod overlay overrides the tag
          env:
            - name: POD_NAMESPACE           # changed by overlay `namespace:`
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: ENV_LABEL               # changed by overlay `labels:`
              valueFrom: { fieldRef: { fieldPath: "metadata.labels['environment']" } }
            - name: LAYER                   # changed by `commonAnnotations:`
              valueFrom: { fieldRef: { fieldPath: "metadata.annotations['kustomize.demo/layer']" } }
            - name: CPU_LIMIT               # changed by prod patch
              valueFrom: { resourceFieldRef: { resource: limits.cpu, divisor: 1m } }
            - name: SECRET_USER             # from secretGenerator
              valueFrom: { secretKeyRef: { name: student-secret, key: username } }
            # ... POD_NAME, POD_IP, NODE_NAME, MEM_LIMIT
          envFrom:
            - configMapRef:
                name: student-config        # from configMapGenerator
          resources:
            requests: { cpu: 50m,  memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          volumeMounts:
            - { name: html,            mountPath: /usr/share/nginx/html }
            - { name: nginx-templates, mountPath: /etc/nginx/templates }
      volumes:
        - { name: html,            configMap: { name: student-html } }
        - { name: nginx-templates, configMap: { name: student-nginx-conf } }
```

### `base/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: student-service
spec:
  type: NodePort
  selector:
    app: student
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 30080
```

### `base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

labels:
  - pairs:
      environment: base
    includeSelectors: false
    includeTemplates: true

commonAnnotations:
  kustomize.demo/layer: base

configMapGenerator:
  - name: student-config
    literals:
      - APP_COURSE=DevOps
      - APP_TRAINER=Ashutosh
      - "APP_MESSAGE=Rendered straight from the base. No overlay applied."
      - "APP_COLOR=#64748b"
  - name: student-html
    files:
      - html/index.html
  - name: student-nginx-conf
    files:
      - nginx/default.conf.template

secretGenerator:
  - name: student-secret
    literals:
      - username=admin
      - password=Pass@123
```

> ⚠️ Values containing `: ` (colon + space) or starting with `#` **must be quoted**, or YAML parses them as a map / comment.

### Preview and deploy base

```bash
kubectl kustomize base                 # or: kustomize build base
kubectl create namespace base
kubectl apply -k base -n base
kubectl get all -n base
```

🌐 Open **http://&lt;node-ip&gt;:30080** → slate page, every row badged **from base**.

---

## 🔵 Step 2 — DEV overlay

### `overlays/dev/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

namespace: dev
namePrefix: dev-

labels:
  - pairs:
      environment: development
      owner: devops
    includeSelectors: false
    includeTemplates: true

commonAnnotations:
  kustomize.demo/layer: dev-overlay
  createdBy: Ashutosh

replicas:
  - name: student-app
    count: 1

configMapGenerator:
  - name: student-config
    behavior: merge                    # change 2 keys, keep the rest from base
    literals:
      - "APP_COLOR=#3b82f6"
      - "APP_MESSAGE=DEV overlay: namespace dev, prefix dev-, 1 replica, NodePort 30081."

patches:
  - target:
      kind: Service
      name: student-service
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: 30081
```

```bash
kubectl kustomize overlays/dev         # preview
kubectl create namespace dev
kubectl apply -k overlays/dev
kubectl get all -n dev
kubectl describe deployment dev-student-app -n dev
```

**Observe**

| | Base | Dev |
|---|---|---|
| Deployment | `student-app` | `dev-student-app` |
| ConfigMap | `student-config-<hash>` | `dev-student-config-<new hash>` |
| Namespace | `base` | `dev` |
| NodePort | 30080 | **30081** |

🌐 Open **http://&lt;node-ip&gt;:30081** → blue page. Course, trainer, image and limits stay **from base**.

---

## 🟢 Step 3 — PROD overlay

### `overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

namespace: prod
namePrefix: prod-

labels:
  - pairs:
      environment: production
      owner: devops
    includeSelectors: false
    includeTemplates: true

commonAnnotations:
  kustomize.demo/layer: prod-overlay
  createdBy: Ashutosh

replicas:
  - name: student-app
    count: 3

images:
  - name: nginx
    newTag: 1.27-alpine

configMapGenerator:
  - name: student-config
    behavior: merge
    literals:
      - "APP_COLOR=#22c55e"
      - "APP_MESSAGE=PROD overlay: namespace prod, prefix prod-, 3 replicas, nginx 1.27, bigger limits, NodePort 30082."

patches:
  - path: resources-patch.yaml         # strategic-merge patch (file)
  - target:                            # JSON6902 patch (inline)
      kind: Service
      name: student-service
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: 30082
```

### `overlays/prod/resources-patch.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: student-app          # base name — matched before the prefix is added
spec:
  template:
    spec:
      containers:
        - name: nginx
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
```

```bash
kubectl kustomize overlays/prod
kubectl create namespace prod
kubectl apply -k overlays/prod
kubectl get all -n prod
kubectl get deployment prod-student-app -n prod -o jsonpath='{.spec.template.spec.containers[0].image}'
```

🌐 Open **http://&lt;node-ip&gt;:30082** → green page, **9 of 12** rows badged **overlay**.
Click **Send 20 requests** and watch 3 different pods answer — that's the `replicas: 3` overlay, live.

---

## 🌐 Step 4 — Open all three pages

```bash
# Node IP
kubectl get nodes -o wide

# minikube
minikube ip
minikube service dev-student-service -n dev --url    # handy if the node IP isn't reachable

# All three NodePort services
kubectl get svc -A | grep student-service
```

| URL | What you should see |
|---|---|
| `http://<node-ip>:30080` | ⚪ **Running as base** — 0 of 12 changed |
| `http://<node-ip>:30081` | 🔵 **Running as development** — namespace, name, label, colour, port changed |
| `http://<node-ip>:30082` | 🟢 **Running as production** — plus image, CPU/memory limits, 3 replicas |

**Using kind?** Create the cluster with port mappings:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - { containerPort: 30080, hostPort: 30080 }
      - { containerPort: 30081, hostPort: 30081 }
      - { containerPort: 30082, hostPort: 30082 }
```

```bash
kind create cluster --config kind-config.yaml
# then open http://localhost:30080, :30081, :30082
```

**Terminal check without a browser**

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
for p in 30080 30081 30082; do echo "== $p"; curl -s http://$NODE:$p/info; echo; done
```

---

## 🔍 Compare outputs side by side

```bash
diff <(kubectl kustomize base) <(kubectl kustomize overlays/dev)
diff <(kubectl kustomize overlays/dev) <(kubectl kustomize overlays/prod)
```

---

## 🧪 Feature reference

<details>
<summary><b>🖼️ Image override</b></summary>

```yaml
images:
  - name: nginx            # image name as written in base
    newTag: 1.27-alpine    # or newName: myregistry/nginx
```
Verify: `kubectl get deploy -n prod -o yaml | grep image:` — page shows nginx `1.27.x`.
</details>

<details>
<summary><b>🗂️ ConfigMap generator</b></summary>

Generated names get a content hash (`student-config-t8t2b89gt8`). Change a value → new hash →
Deployment reference updated → **pods roll automatically**.
`behavior: merge` in an overlay changes only the keys you list.

```bash
kubectl get configmap -n dev
```
</details>

<details>
<summary><b>🔐 Secret generator</b></summary>

```yaml
secretGenerator:
  - name: student-secret
    literals:
      - username=admin
      - password=Pass@123
```
```bash
kubectl get secrets -n dev
kubectl get secret -n dev -l environment=development -o jsonpath='{.items[0].data.username}' | base64 -d
```
> Demo only. Never commit real passwords — use Sealed Secrets, SOPS or External Secrets.
</details>

<details>
<summary><b>🏷️ Labels (replacement for deprecated <code>commonLabels</code>)</b></summary>

```yaml
labels:
  - pairs:
      owner: devops
      environment: development
    includeSelectors: false   # don't touch selectors (they're immutable)
    includeTemplates: true    # also label pods
```
`commonLabels` still works but also rewrites selectors, which breaks `apply` if you change a value later.

```bash
kubectl get deployment -n dev --show-labels
```
</details>

<details>
<summary><b>📝 Common annotations</b></summary>

```yaml
commonAnnotations:
  createdBy: Ashutosh
  training: kustomize
```
```bash
kubectl describe deployment dev-student-app -n dev
```
</details>

<details>
<summary><b>🔤 namePrefix / nameSuffix</b></summary>

```yaml
namePrefix: dev-     # student-app → dev-student-app
nameSuffix: -v1      # student-app → student-app-v1
```
Kustomize also rewrites every reference (ConfigMap, Secret, volume) to the new names.
</details>

<details>
<summary><b>📦 Namespace without editing YAML</b></summary>

```yaml
namespace: prod
```
Every namespaced resource is placed in `prod`. Create the namespace first, or add a `Namespace` resource to the overlay.
</details>

<details>
<summary><b>🩹 Patches — two styles</b></summary>

**Strategic merge** (looks like the resource, only changed fields):
```yaml
patches:
  - path: resources-patch.yaml
```

**JSON6902** (precise operations):
```yaml
patches:
  - target: { kind: Service, name: student-service }
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: 30082
```
</details>

---

## 🧹 Cleanup

```bash
kubectl delete -k overlays/prod
kubectl delete -k overlays/dev
kubectl delete -k base -n base
kubectl delete namespace base dev prod
```

---

## 🛠️ Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot unmarshal object into ... literals` | Quote literals containing `: ` → `- "KEY=a: b"` |
| `provided port is already allocated` | Another Service owns that NodePort. Check `kubectl get svc -A \| grep 3008` |
| Page says *Couldn't reach /info* | Pod not ready: `kubectl get pods -n <ns>` and `kubectl logs -n <ns> deploy/<name>` |
| Can't open the NodePort | minikube: use `minikube ip`; kind: add `extraPortMappings`; cloud: open firewall 30080-30082 |
| Only 1 pod answers in prod | Wait for all 3 pods to be Ready; each request opens a new connection so kube-proxy can spread it |

---

## ⚡ Useful commands

```bash
kubectl kustomize base               kustomize build base
kubectl kustomize overlays/dev       kustomize build overlays/dev
kubectl kustomize overlays/prod      kustomize build overlays/prod

kubectl apply  -k base -n base       kubectl delete -k base -n base
kubectl apply  -k overlays/dev       kubectl delete -k overlays/dev
kubectl apply  -k overlays/prod      kubectl delete -k overlays/prod
```

---

## 🎤 Interview questions (with short answers)

<details><summary><b>1. What is Kustomize?</b></summary>A template-free way to customise Kubernetes YAML. Built into kubectl (<code>-k</code>).</details>
<details><summary><b>2. Why use Kustomize?</b></summary>Keep one plain-YAML base and layer environment differences on top, without copying files or learning a template language.</details>
<details><summary><b>3. Base vs Overlay?</b></summary>Base = shared, reusable manifests. Overlay = references the base and applies environment-specific changes.</details>
<details><summary><b>4. Helm vs Kustomize?</b></summary>Helm: templating + packaging + releases/rollback, values files. Kustomize: patches over plain YAML, no templates, no release state. They're often combined.</details>
<details><summary><b>5. namePrefix?</b></summary>Adds a prefix to resource names and updates all references.</details>
<details><summary><b>6. nameSuffix?</b></summary>Adds a suffix to resource names and updates all references.</details>
<details><summary><b>7. configMapGenerator?</b></summary>Generates a ConfigMap from literals/files/env files with a content hash so pods restart when config changes.</details>
<details><summary><b>8. secretGenerator?</b></summary>Same as configMapGenerator but produces a Secret (base64, not encrypted).</details>
<details><summary><b>9. Override images?</b></summary><code>images:</code> with <code>name</code> plus <code>newTag</code>, <code>newName</code> or <code>digest</code>.</details>
<details><summary><b>10. Patch resources?</b></summary><code>patches:</code> with a strategic-merge file or a JSON6902 inline patch and a <code>target</code>.</details>
<details><summary><b>11. kubectl apply -k?</b></summary>Builds the kustomization and applies the result in one step.</details>
<details><summary><b>12. kubectl kustomize?</b></summary>Builds and prints the final YAML without applying — a dry run.</details>
<details><summary><b>13. Manage multiple environments?</b></summary>One base, one overlay per environment (dev, staging, prod), each in its own namespace.</details>
<details><summary><b>14. commonLabels?</b></summary>Adds labels everywhere including selectors. Deprecated in favour of <code>labels:</code> with <code>includeSelectors</code> control.</details>
<details><summary><b>15. commonAnnotations?</b></summary>Adds annotations to all resources and pod templates.</details>

---

<div align="center">

**Same `index.html`. Same `deployment.yaml`. Three different pages.**
That's base + overlay. 🎉

</div>
