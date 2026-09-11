# Kyverno — Policy-as-Code for Kubernetes

A hands-on guide to what Kyverno is, why you'd use it, how it works, when to reach for it, and a
copy-paste demo that enforces real policies on a live cluster.

> **Syntax note:** The policy-level field `spec.validationFailureAction` is **deprecated** (since
> Kyverno 1.13) and will be removed in a future release. This guide uses the current per-rule form
> **`spec.rules[*].validate.failureAction`**. All demo manifests below already use the new syntax.

---

## What is Kyverno?

Kyverno (Greek for "govern") is a **Kubernetes-native policy engine**. It runs as an admission
controller inside your cluster and checks every resource that is created or updated against a set of
rules you define.

The key idea: **policies are written in plain YAML**, the same format you already use for
Deployments, Services, and Ingresses. There is no new domain-specific language to learn (unlike
OPA/Gatekeeper's Rego).

A Kyverno policy can do three things:

| Capability   | What it does                                                        |
|--------------|--------------------------------------------------------------------|
| **Validate** | Allow or block a resource based on whether it matches a pattern.   |
| **Mutate**   | Automatically inject or modify fields (e.g. add default labels).   |
| **Generate** | Create dependent resources automatically (e.g. a default NetworkPolicy per namespace). |

This guide focuses on **validation**, the most common use case.

---

## Why use Kyverno?

Kubernetes gives teams a lot of freedom — and one missing label, one `privileged: true`, or one
container running as root can turn into a security incident or an outage. Kyverno adds **guardrails**
without slowing teams down.

- **No new language.** Policies are YAML. Anyone who can read a manifest can read a policy.
- **Native to Kubernetes.** Installed as a normal workload; policies are Custom Resources (CRDs).
- **Shift-left friendly.** The same policies can run in CI (via the Kyverno CLI) *before* anything
  hits the cluster.
- **Audit or enforce.** Start in `Audit` mode to observe violations without breaking anything, then
  flip to `Enforce` when you're confident.
- **Rich reporting.** Violations are recorded in `PolicyReport` / `ClusterPolicyReport` resources.
- **Beyond validation.** It can also mutate resources to fix them and generate supporting resources.

---

## How does it work?

```
        kubectl apply / CI pipeline
                    │
                    ▼
        Kubernetes API Server
                    │  (AdmissionReview webhook)
                    ▼
        ┌───────────────────────┐
        │   Kyverno controller  │
        │  evaluates matching   │
        │      policies         │
        └───────────────────────┘
             │              │
     matches │              │ violates
     pattern │              │ pattern
             ▼              ▼
        ✅ ALLOW      failureAction?
                       ├─ Enforce → ❌ BLOCK request
                       └─ Audit   → ✅ ALLOW + record in PolicyReport
```

1. You install Kyverno; it registers **admission webhooks** with the API server.
2. Every create/update request for matching resources is sent to Kyverno.
3. Kyverno evaluates each rule's `match` block (what to check) and `validate` block (what must be
   true).
4. The rule's **`failureAction`** decides the outcome of a failed check:
   - **`Enforce`** → the request is **rejected** and the user sees the rule's `message`.
   - **`Audit`** → the request is **allowed**, but the violation is written to a policy report.

### `ClusterPolicy` vs `Policy`

- **`ClusterPolicy`** — cluster-wide, applies across all namespaces. Used in this demo.
- **`Policy`** — scoped to a single namespace.

---

## When should you use it?

Reach for Kyverno when you want to enforce standards automatically instead of relying on reviews and
tribal knowledge. Common cases:

- **Security baselines** — block root containers, `privileged`, `hostNetwork`, `latest` tags.
- **Governance / cost** — require `team`, `owner`, or `cost-center` labels on every workload.
- **Reliability** — require CPU/memory requests and limits, liveness/readiness probes.
- **Compliance** — enforce Pod Security Standards, allowed registries, or signed images.
- **Automation** — auto-add default labels (mutate) or default NetworkPolicies (generate).

**When *not* to reach for it:** for simple field defaults a mutating webhook already handles, or for
logic that belongs in application code rather than admission control. Kyverno does policy enforcement
the Kubernetes way — it doesn't try to be everything.

---

## Demo

This demo installs Kyverno, then walks through two policies:

1. **Require a `team` label** on every Pod.
2. **Require containers to run as non-root.**

For each policy you'll apply a "bad" Pod that gets **blocked** and a "good" Pod that is **allowed** —
demonstrating `failureAction: Enforce`.

### Prerequisites

- A running Kubernetes cluster (kind, minikube, or a cloud cluster).
- `kubectl` configured to talk to it.

### Step 1 — Install Kyverno

```bash
kubectl create namespace kyverno
kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
```

Wait for the controllers to become ready before applying any policies:

```bash
kubectl -n kyverno wait --for=condition=Ready pods --all --timeout=120s
kubectl -n kyverno get pods
```

> If you apply a policy before Kyverno is fully up, the webhook may not be registered yet and your
> "bad" Pod could slip through. Always wait for Ready.

---

### Part A — Require a `team` label

#### Step 2 — Apply the policy (`mandatory.yaml`)

```yaml
# mandatory.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  rules:
  - name: check-team-label
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      # failureAction now lives inside the rule's validate block (was spec.validationFailureAction)
      failureAction: Enforce
      message: "team label is required"
      pattern:
        metadata:
          labels:
            team: "?*"     # ?* means "one or more characters" — the label must exist and be non-empty
```

```bash
kubectl apply -f mandatory.yaml
kubectl get clusterpolicy require-team-label
```

#### Step 3 — Apply a Pod that violates it (`badpod.yaml`)

```yaml
# badpod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: badpod
spec:
  containers:
  - name: nginx
    image: nginx
```

```bash
kubectl apply -f badpod.yaml
```

**Expected result — blocked:**

```
Error from server: ... resource Pod/default/badpod was blocked due to the following policies:
require-team-label:
  check-team-label: 'team label is required'
```

#### Step 4 — Apply a Pod that passes (`successpod.yaml`)

```yaml
# successpod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: goodpod
  labels:
    team: devops
spec:
  containers:
  - name: nginx
    image: nginx
```

```bash
kubectl apply -f successpod.yaml
kubectl get pod goodpod
```

**Expected result — allowed** (`pod/goodpod created`).

---

### Part B — Require non-root containers

#### Step 5 — Apply the security policy (`securitypolicy.yaml`)

```yaml
# securitypolicy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-non-root
spec:
  rules:
  - name: validate-security-context
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      failureAction: Enforce
      message: "runAsNonRoot required"
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
```

```bash
kubectl apply -f securitypolicy.yaml
kubectl get clusterpolicy require-non-root
```

#### Step 6 — Apply a Pod that violates it (`badsecurity.yaml`)

```yaml
# badsecurity.yaml
apiVersion: v1
kind: Pod
metadata:
  name: rootpod
  labels:
    team: devops          # satisfies Part A, but has no runAsNonRoot → blocked by Part B
spec:
  containers:
  - name: nginx
    image: nginx
```

```bash
kubectl apply -f badsecurity.yaml
```

**Expected result — blocked:**

```
Error from server: ... resource Pod/default/rootpod was blocked due to the following policies:
require-non-root:
  validate-security-context: 'runAsNonRoot required'
```

#### Step 7 — Apply a Pod that passes (`goodsecurity.yaml`)

```yaml
# goodsecurity.yaml
apiVersion: v1
kind: Pod
metadata:
  name: securepod
  labels:
    team: devops
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: nginx
    image: nginx
```

```bash
kubectl apply -f goodsecurity.yaml
kubectl get pod securepod
```

**Expected result — allowed** (`pod/securepod created`).

---

## Switching between Enforce and Audit

`failureAction` is the switch that controls whether a violation blocks or just reports. A safe
rollout pattern is to start in **`Audit`**, watch the reports, then move to **`Enforce`**.

```yaml
    validate:
      failureAction: Audit      # observe only — nothing is blocked
      message: "team label is required"
      pattern:
        metadata:
          labels:
            team: "?*"
```

> When using `Audit`, set `spec.emitWarning: true` on the policy if you also want the violation
> surfaced as a warning in the admission response.

Inspect what Audit mode recorded:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl describe clusterpolicyreport <name>
```

### Per-namespace overrides

You can enforce in some namespaces and only audit in others using `failureActionOverrides`
(ClusterPolicy only):

```yaml
    validate:
      failureAction: Audit
      failureActionOverrides:
      - action: Enforce
        namespaces:
        - production
      - action: Audit
        namespaces:
        - dev
      message: "team label is required"
      pattern:
        metadata:
          labels:
            team: "?*"
```

---

## Verifying and cleaning up

Check policies and reports:

```bash
kubectl get clusterpolicy
kubectl get clusterpolicyreport
```

Remove the demo resources:

```bash
kubectl delete pod goodpod securepod --ignore-not-found
kubectl delete clusterpolicy require-team-label require-non-root
```

Uninstall Kyverno entirely:

```bash
kubectl delete -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
kubectl delete namespace kyverno
```

---

## Troubleshooting

| Symptom                                   | Likely cause / fix                                                        |
|-------------------------------------------|--------------------------------------------------------------------------|
| Bad Pod is *not* blocked                  | Kyverno pods weren't Ready when you applied the policy. Re-apply.         |
| `unknown field "validationFailureAction"` | You're on a newer engine — use `validate.failureAction` (as in this guide). |
| No error but no enforcement               | `failureAction` is `Audit`, not `Enforce`. Check the policy.              |
| Webhook timeout errors                    | Kyverno controller not healthy: `kubectl -n kyverno get pods`.           |

---

## References

- Kyverno docs — Validate Rules: https://kyverno.io/docs/writing-policies/validate/
- Policy Settings (deprecations): https://kyverno.io/docs/policy-types/cluster-policy/policy-settings/
- Kyverno GitHub: https://github.com/kyverno/kyverno
