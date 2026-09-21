# Falco on Kubernetes — Production Runtime Security Demo

A hands-on, self-contained demo that teaches what [Falco](https://falco.org) does, why it matters, and how to run it the way you would in production. You'll install Falco with the modern eBPF driver, load custom rules, trigger real (but harmless) detections, and route alerts to Slack / a webhook via Falcosidekick.

> **Falco is the CNCF runtime security engine.** It watches the *syscalls* your workloads make (plus Kubernetes audit logs and cloud logs) and screams when something looks like an intrusion — a shell spawned in a container, a read of `/etc/shadow`, an unexpected outbound connection, a package manager running in prod. It is detection & alerting, not enforcement.

---

## Table of contents

1. [What Falco actually is](#1-what-falco-actually-is)
2. [How it works (the architecture)](#2-how-it-works)
3. [What you can detect](#3-what-you-can-detect)
4. [Prerequisites](#4-prerequisites)
5. [Quick start](#5-quick-start)
6. [Running the demo scenarios](#6-running-the-demo-scenarios)
7. [Writing custom rules](#7-writing-custom-rules)
8. [Alerting & response (Falcosidekick)](#8-alerting--response)
9. [Taking it to production](#9-taking-it-to-production)
10. [Troubleshooting](#10-troubleshooting)
11. [Cleanup](#11-cleanup)

---

## 1. What Falco actually is

Traditional security scanners look at your images **before** they run (Trivy, Grype). Falco is different — it looks at behavior **while containers run**. That's the "runtime" in runtime security.

The core idea: almost everything a program does that matters — opening a file, spawning a process, opening a network socket, changing a file's permissions — goes through the Linux **kernel** as a *system call*. Falco taps into that stream, enriches each event with container and Kubernetes context (pod, namespace, image, labels), evaluates it against a rule set, and fires an alert when a rule matches.

**Why teams run it:**

| Concern | How Falco helps |
|---|---|
| Container breakout / privilege escalation | Detects `setuid`, unexpected `CAP_SYS_ADMIN` use, writes to `/proc` |
| Reverse shells & C2 | Flags shells spawned by web servers, outbound connections to odd ports |
| Data exfiltration | Reads of sensitive files, unexpected `curl`/`wget` from app pods |
| Cryptojacking | Known miner binaries, spikes in outbound to mining pools |
| Supply-chain / drift | Package managers (`apt`, `pip`) running in a "immutable" prod container |
| Compliance (PCI, SOC2, NIST) | Falco maps rules to MITRE ATT&CK and compliance frameworks |

Falco is a **graduated CNCF project** (same maturity tier as Kubernetes, Prometheus, Envoy).

---

## 2. How it works

```
                       ┌───────────────────────────────────────┐
                       │            Falco (DaemonSet)           │
   ┌───────────┐       │   ┌──────────┐   ┌────────────────┐    │
   │  Kernel   │─syscalls─▶│  Driver  │──▶│  Rules Engine  │    │
   │ (eBPF /   │       │   │ (eBPF)   │   │ (evaluate +    │    │
   │  modern-  │       │   └──────────┘   │  enrich w/ k8s)│    │
   │  bpf)     │       │        ▲         └───────┬────────┘    │
   └───────────┘       │        │                 │             │
                       │   ┌────┴─────┐     ┌──────▼─────────┐  │
   k8s audit logs ─────────▶│ Plugins │     │    Outputs     │  │
   cloud logs (AWS…) ──────▶│         │     │ stdout / json  │  │
                       │   └──────────┘     │ gRPC / webhook │  │
                       └──────────────────────────┬──────────┘  │
                                                   │
                                        ┌──────────▼──────────┐
                                        │    Falcosidekick     │
                                        │ Slack, PagerDuty,    │
                                        │ Loki, Elastic, S3,   │
                                        │ Prometheus, FaaS…    │
                                        └──────────────────────┘
```

**Key pieces:**

- **Driver** — how Falco reads syscalls. Three options:
  - `modern_ebpf` (**recommended**, CO-RE eBPF, no kernel headers needed, kernel ≥ 5.8)
  - `ebpf` (legacy probe)
  - `kernel_module` (kmod; avoid on managed nodes)
- **Rules engine** — evaluates a YAML rule set. Ships with a maintained default rule set (`falco_rules.yaml`) plus your custom rules.
- **Plugins** — extend Falco beyond syscalls: Kubernetes Audit, AWS CloudTrail, GitHub, Okta, etc.
- **Outputs** — where alerts go. In prod you almost always add **Falcosidekick** as a fan-out layer.

It runs as a **DaemonSet** — one Falco pod per node — because syscalls are a per-node, kernel-level concern.

---

## 3. What you can detect

The default rule set alone catches dozens of behaviors. A representative slice:

- `Terminal shell in container` — a shell (`bash`, `sh`) started interactively inside a running container
- `Read sensitive file untrusted` — reads of `/etc/shadow`, `/etc/sudoers`, SSH keys
- `Write below etc` — writes into `/etc` by non-trusted programs
- `Launch privileged container` / `Launch sensitive mount container`
- `Contact K8S API server from container`
- `Unexpected outbound connection` (with a rule you scope to your egress policy)
- `Package management process launched` — `apt`, `yum`, `pip` in a running prod container
- `Detect crypto miners using the Stratum protocol`
- `Modify binary dirs` — tampering with `/bin`, `/usr/bin`

You'll trigger several of these yourself in [section 6](#6-running-the-demo-scenarios).

---

## 4. Prerequisites

- A Kubernetes cluster. For the demo, any of:
  - [`kind`](https://kind.sigs.k8s.io/) (works, but see note below), `minikube`, k3s, or a real cluster.
  - **Node kernel ≥ 5.8** for `modern_ebpf` (any recent cloud node image qualifies).
- `kubectl` and `helm` (v3) installed and pointed at the cluster.
- Cluster-admin (Falco needs privileged access to load its eBPF probe).

> **kind / Docker Desktop caveat:** nested containers share the host kernel, so syscalls from demo pods are visible, but on macOS/Windows the "host" is a Linux VM. It works for learning. For a faithful production feel, use a real Linux node (a cloud VM, minikube with `--driver=kvm2`, or k3s on a Linux box).

Verify:

```bash
kubectl get nodes -o wide          # note the kernel version column
helm version
```

---

## 5. Quick start

```bash
# From the repo root
make install        # adds the Helm repo and installs Falco + Falcosidekick + custom rules
make status         # wait until the DaemonSet pods are Running
make logs           # stream Falco alerts (leave this open in a second terminal)
```

Or do it by hand:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  -f install/values.yaml
```

`install/values.yaml` turns on the modern eBPF driver, JSON output, Falcosidekick, and mounts our custom rules. See [section 8](#8-alerting--response) to wire Slack.

Confirm it's healthy:

```bash
kubectl -n falco get pods
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20
```

You should see Falco report the rules it loaded and `Falco initialized with configuration file`.

---

## 6. Running the demo scenarios

> Everything below is **benign** — standard, well-documented Falco trigger events used purely to prove detection works. Nothing here is an actual exploit; it's the security equivalent of setting off a smoke detector with a match.

Keep `make logs` open in one terminal, then in another:

```bash
make demo           # runs all scenarios with pauses, or run them individually:

./demo/01-shell-in-container.sh      # → "Terminal shell in container"
./demo/02-read-sensitive-file.sh     # → "Read sensitive file untrusted"
./demo/03-write-below-etc.sh         # → "Write below etc"
./demo/04-package-mgmt.sh            # → "Package management launched in container"
kubectl apply -f demo/05-crypto-miner-sim.yaml   # → custom "Suspicious miner-like process" rule
```

Watch the alert appear in the Falco log stream within a second or two, tagged with the pod, namespace, image, and offending command. That immediacy — kernel event to alert in real time — is the whole point.

Each script is heavily commented so you can see exactly which syscall it triggers and which rule catches it.

---

## 7. Writing custom rules

Falco rules are YAML. Three building blocks:

- **`list`** — reusable sets of values (`[bash, sh, zsh]`)
- **`macro`** — reusable conditions (`spawned_process and container`)
- **`rule`** — the alert itself: a condition, an output template, and a priority

Example from [`rules/custom-rules.yaml`](rules/custom-rules.yaml):

```yaml
- rule: Unexpected outbound connection from app pods
  desc: >
    An application pod opened an outbound connection to a destination
    outside our known allow-list. Possible C2 or exfiltration.
  condition: >
    outbound and container
    and k8s.ns.name = "demo-apps"
    and not fd.sip in (allowed_egress_ips)
  output: >
    Unexpected egress (command=%proc.cmdline connection=%fd.name
    pod=%k8s.pod.name ns=%k8s.ns.name image=%container.image.repository)
  priority: WARNING
  tags: [network, mitre_exfiltration, T1041]
```

**Tips that matter in production:**

- **Tune, don't disable.** Silencing a noisy default rule is worse than scoping it. Use `macro` overrides and exception lists.
- Use **`exceptions`** (Falco ≥ 0.32) instead of piling `and not ...` clauses — they're auditable and structured.
- Tag every rule with a **MITRE ATT&CK** technique so alerts map to a framework your SOC understands.
- Keep custom rules in **your** repo (like this one), version-controlled, loaded via `customRules` in Helm — never edit the vendored default file in place.

Reload rules without reinstalling:

```bash
helm upgrade falco falcosecurity/falco -n falco -f install/values.yaml
# Falco hot-reloads rule files; a pod restart is only needed for config changes.
```

---

## 8. Alerting & response

Raw Falco output is a firehose to stdout. **Falcosidekick** is the fan-out layer that turns alerts into something actionable — 50+ destinations (Slack, Teams, PagerDuty, Opsgenie, Elastic, Loki, S3, Prometheus metrics, and serverless functions for auto-response).

It's enabled in `install/values.yaml`. To send alerts to Slack, set your webhook:

```bash
helm upgrade falco falcosecurity/falco -n falco \
  -f install/values.yaml \
  --set falcosidekick.config.slack.webhookurl="https://hooks.slack.com/services/XXX/YYY/ZZZ" \
  --set falcosidekick.config.slack.minimumpriority="warning"
```

Falcosidekick also ships a **Web UI** (a dashboard of recent alerts). Enable it in the values file, then:

```bash
kubectl -n falco port-forward svc/falco-falcosidekick-ui 2802:2802
# open http://localhost:2802  (default login: admin / admin — change it!)
```

**Response automation:** point Falcosidekick at a FaaS destination (Kubeless, OpenFaaS, or a webhook to your own controller) to react to alerts — e.g. label a pod, cordon a node, or delete the offending pod. This is how you evolve from *detection* to *response*. Be conservative: auto-killing pods can cause outages; start with alert-only and graduate specific high-confidence rules to automated action.

---

## 9. Taking it to production

The demo defaults are close to prod-ready, but before you rely on this:

**Driver & performance**
- Use `modern_ebpf`. It's the least operationally painful (no kernel headers, no kmod) and safest on managed node pools.
- Falco's CPU cost scales with syscall volume. Set **resource requests/limits** (see values file) and watch the `falco_n_evts` / `falco_n_drops` metrics — **drops mean you're missing events**, which is a security gap, not just a perf issue.

**Rules**
- Start from the maintained default rule set, then tune to your environment over 1–2 weeks. Expect noise from legitimate ops tooling (backup agents, node problem detector) — scope those out with exceptions, don't disable whole rules.
- Pin the rules version. Don't auto-pull `latest` rules into a running fleet without a review step.

**Reliability & scale**
- One DaemonSet pod per node; make sure it tolerates your taints and has a `priorityClassName` so it isn't evicted first.
- Ship alerts off-node immediately (Falcosidekick → durable sink like S3/Elastic). A node that gets compromised shouldn't also hold the only copy of the evidence.

**Coverage beyond syscalls**
- Add the **Kubernetes Audit Logs plugin** to catch control-plane abuse (exec into pods, secret access, RBAC changes) that never touches a node's syscalls.
- On cloud, add the **CloudTrail / cloud-logs plugins** for a unified detection story.

**Security of Falco itself**
- Falco runs privileged by design. Lock down who can edit its rules and Helm values (they're effectively part of your detection boundary).
- Monitor Falco's own liveness — a silenced sensor is invisible. Alert on the DaemonSet dropping below `desiredNumberScheduled`.

**Compliance**
- Falco rules carry `tags` mapping to MITRE ATT&CK and to PCI/NIST controls. Export those to your GRC tooling to evidence runtime monitoring controls.

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Pods `CrashLoopBackOff`, log mentions driver | Kernel too old for `modern_ebpf` — switch `driver.kind` to `ebpf`, or update node image |
| No alerts when running demo | Driver not loaded (`kubectl logs` should say `driver ... loaded`); on kind/mac verify you're on a Linux node |
| Flood of alerts on install | Normal for the first minutes as it sees existing processes; tune exceptions |
| `falco_n_drops` climbing | Under-resourced or too many syscalls — raise limits, reduce ruleset scope, enable `modern_ebpf` |
| Slack silent | Wrong `minimumpriority` (alert priority below threshold) or bad webhook — check Falcosidekick logs |

Useful commands:

```bash
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco -f
kubectl -n falco logs deploy/falco-falcosidekick -f
kubectl -n falco get daemonset falco -o wide
```

---

## 11. Cleanup

```bash
make clean          # or:
kubectl delete -f demo/05-crypto-miner-sim.yaml --ignore-not-found
helm uninstall falco -n falco
kubectl delete ns falco demo-apps --ignore-not-found
```

---

## Further reading

- Falco docs — https://falco.org/docs/
- Rule-writing reference — https://falco.org/docs/rules/
- Falcosidekick — https://github.com/falcosecurity/falcosidekick
- Supported fields (`%proc.cmdline`, `%k8s.pod.name`, …) — https://falco.org/docs/reference/rules/supported-fields/

---

*This is a teaching demo. All "attack" scenarios are benign trigger events used to demonstrate detection. Tune rules and validate coverage before depending on Falco in a real environment.*
