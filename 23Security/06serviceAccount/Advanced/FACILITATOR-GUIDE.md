# Facilitator Guide — Kubernetes ServiceAccounts for Production

**Audience:** people new to Kubernetes (gentle) · **Length:** 30–45 min · **Format:** live-taught with a running demo

This guide is a script. It tells you what to *say*, what to *run*, what to *point at*, and what to *ask the room* — in order, on a clock. Pair it with the lab in this folder (`manifests/`, `scripts/`).

> **The one sentence they must leave with:**
> *Every pod has an identity — in production you give each workload its own, grant it only what it needs, and don't hand it a key at all if it never opens the door.*

---

## Before you start (do this ~30 min early)

- [ ] A cluster is up: `kubectl get nodes` returns Ready nodes.
- [ ] **Warm the images.** Run `./scripts/01-setup.sh` once, watch it go green, then `./scripts/99-cleanup.sh`. This caches the container images on the node so your *live* deploy is fast, not a 2-minute pull in front of the room.
- [ ] Terminal font is **big** (18–24pt). Newcomers can't follow tiny text.
- [ ] Have two things open: this guide, and one terminal in the `production-serviceaccount-demo/` folder.
- [ ] Optional: a second terminal already running `kubectl -n acme-prod get pods -w` so the room sees pods appear live.
- [ ] Know your escape hatch: if any live command misbehaves, the matching `./scripts/0X.sh` does the same thing — run that and keep talking.

---

## Learning objectives (say these out loud at the start)

By the end, they'll be able to:

1. Explain what a ServiceAccount is, in one sentence.
2. Name the three RBAC pieces — **ServiceAccount, Role, RoleBinding** — and what each does.
3. State the two production rules: *least privilege* and *no token if you don't need one*.
4. Use `kubectl auth can-i` to check permissions.

---

## The analogy you'll reuse all session

Keep coming back to this — it's the spine of the talk.

| Kubernetes thing | Office building analogy |
|---|---|
| **Pod** | An employee (does the work) |
| **ServiceAccount** | Their ID badge (says *who* they are) |
| **Role** | The list of doors a badge is allowed to open |
| **RoleBinding** | Actually programming that badge to open those doors |
| **`default` ServiceAccount** | A blank badge that opens nothing |
| **Token** | The keycard chip inside the badge |
| **`automountServiceAccountToken: false`** | Don't give a keycard to someone who never opens a door |
| **Least privilege** | Program the badge for only the doors they need |
| **Namespaced Role** | The badge works in *this building* only |

---

## Timing at a glance

| Time | Section | Mode |
|------|---------|------|
| 0:00–3:00 | Hook + objectives | talk |
| 3:00–5:00 | 60-second Kubernetes primer | talk |
| 5:00–11:00 | The mental model (the 3 badge pieces) | talk + one diagram |
| 11:00–14:00 | The story: two workloads | talk |
| 14:00–22:00 | **Live demo:** deploy & watch it work | run |
| 22:00–26:00 | Prove what it *can* do | run |
| 26:00–32:00 | Prove what it *can't* do (the payoff) | run |
| 32:00–35:00 | Production recap | talk |
| 35:00–45:00 | Q&A (buffer) | talk |

Running long? The compressible parts are the primer (3:00) and Q&A. Never cut the denial demo (26:00) — that's the memorable moment.

---

## 0:00–3:00 — Hook + objectives

🎯 **Goal:** make them care before any jargon.

🗣 **Say:**
> "Quick show of hands — who's had an app get hacked, or worried about it? Here's a Kubernetes fact that surprises people: *every* running app is automatically given an identity and, often, a key to the cluster's control system. Most apps never need that key. Today we'll see how attackers abuse that, and the handful of settings that shut it down. It's not hard — it's mostly about being deliberate."

Then read the **learning objectives** above.

❓ **Ask the room:** "Who here has used `kubectl` before?" — this tells you how gentle to go.

---

## 3:00–5:00 — 60-second Kubernetes primer

🎯 **Goal:** give absolute newcomers just enough to follow.

🗣 **Say (keep it to a minute):**
> "Two words you'll hear me use. A **pod** is just your app running in a box — think 'one employee.' A **namespace** is a folder that groups related pods — think 'one building' or one team's area. That's all you need for today."

⚠️ **Watch out:** resist teaching more. If someone asks about Deployments, say "a Deployment just keeps pods running — treat it as 'the app' for now" and move on.

---

## 5:00–11:00 — The mental model: three pieces

🎯 **Goal:** the core concept. Go slow here; everything later builds on it.

🗣 **Say, building the badge analogy:**
> "When a pod talks to Kubernetes' control system — the API — it has to prove who it is. It does that with a **ServiceAccount**. That's the pod's *badge*.
>
> A badge by itself opens nothing. To grant access you write a **Role** — literally a list like 'may read pods, may read this one config file.' Then a **RoleBinding** connects the Role to the badge. Badge + Role + Binding — that's the whole system."

Show the diagram (open `README.md` in this folder, or draw it):

```
 ServiceAccount  ──(RoleBinding)──▶  Role
   (the badge)                      (allowed doors)
```

🗣 **The important default — say this clearly:**
> "Here's the catch. If you *don't* choose a badge, your pod gets the built-in `default` one. Sometimes that's harmless because it's blank. But teams often over-grant permissions and every pod inherits them. So the risk isn't the badge — it's an over-powered badge on a pod that gets hacked."

❓ **Ask the room:** "If an app that just serves a web page gets compromised, should it be able to read every password in the cluster?" (Answer: no — that's where we're headed.)

---

## 11:00–14:00 — The story: two workloads

🎯 **Goal:** frame the demo so the payoff lands.

🗣 **Say:**
> "We'll deploy two apps into one namespace. They show the two situations you'll actually meet in production."

| App | Does it need to talk to the API? | What we do |
|-----|----------------------------------|-----------|
| `web-app` | **No** — it just serves pages | Give it a badge with **no keycard at all** |
| `reporter` | **Yes** — it reads some cluster info | Give it a badge that opens **exactly two doors, and no more** |

🗣 **Say:**
> "Then — and this is the fun part — we'll try to make the `reporter` do things it shouldn't, and watch Kubernetes slam the door."

---

## 14:00–22:00 — LIVE DEMO: deploy and watch it work

🎯 **Goal:** make it real.

💻 **Run** (type it; it reads better than a script here):
```bash
kubectl apply -f manifests/
kubectl -n acme-prod rollout status deploy/reporter
```

🗣 **While it rolls out, say:**
> "That one command created the namespace, both badges, the Role, the binding, and both apps."

✅ **Show what exists:**
```bash
kubectl -n acme-prod get sa,role,rolebinding,deploy
```
🗣 Point at each line and name it with the analogy: "there's the badge… there's the door list… there's the binding."

💻 **Now watch the reporter actually use its access:**
```bash
kubectl -n acme-prod logs deploy/reporter -f
```
✅ It prints the pods it can see and the one config it's allowed to read, every 30 seconds. Let it print once or twice, then **Ctrl-C**.

🗣 **Say:**
> "So the reporter's badge works — it can read what we allowed. Now the other app."

💻 **Prove the web-app has no keycard:**
```bash
kubectl -n acme-prod exec deploy/web-app -- ls /var/run/secrets/kubernetes.io/serviceaccount
```
✅ Output: **`No such file or directory`.**

🗣 **Say (land the point):**
> "There's literally no keycard inside this pod. If an attacker breaks into it, there's no cluster key to steal. That's one line of config, and it's the highest-value thing you'll do to most of your apps."

⚠️ **If `rollout status` hangs:** run `kubectl -n acme-prod get pods` and read the STATUS/events aloud (usually still pulling an image). Fall back to `./scripts/01-setup.sh` if needed and keep narrating.

---

## 22:00–26:00 — Prove what it CAN do

🎯 **Goal:** introduce the everyday tool for reasoning about access.

🗣 **Say:**
> "You don't have to deploy anything to check permissions. You can just *ask* the cluster with `kubectl auth can-i`. Watch."

💻 **Run these one at a time** (pause on each answer):
```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:acme-prod:reporter -n acme-prod        # yes

kubectl auth can-i get configmaps/app-config \
  --as=system:serviceaccount:acme-prod:reporter -n acme-prod        # yes
```
✅ Each prints a clean **`yes`**.

🗣 **Say:**
> "`--as` means 'pretend to be this badge.' Super handy for checking a workload's access before you ship it. Now let's ask about things it *shouldn't* be able to do."

---

## 26:00–32:00 — Prove what it CAN'T do (the payoff)

🎯 **Goal:** the memorable moment. This is why least privilege matters.

💻 **Keep asking `can-i` — the answers flip to `no`:**
```bash
kubectl auth can-i get secrets \
  --as=system:serviceaccount:acme-prod:reporter -n acme-prod        # no

kubectl auth can-i get configmaps/other-config \
  --as=system:serviceaccount:acme-prod:reporter -n acme-prod        # no

kubectl auth can-i delete pods \
  --as=system:serviceaccount:acme-prod:reporter -n acme-prod        # no
```

🗣 **Narrate the three `no`s:**
> "Can't read secrets — we never granted that. Can't read a *different* config file — we scoped it to one specific file by name. Can't delete anything — we only gave it read access. Same badge, three closed doors."

💻 **Then show it's real from inside the pod** (not just theory):
```bash
kubectl -n acme-prod exec deploy/reporter -- kubectl get secret app-secret
```
✅ Output: **`Error from server (Forbidden): ... cannot get resource "secrets" ...`**

🗣 **Say:**
> "That's Kubernetes refusing a real request from a real running app. If this pod were compromised, the attacker is stuck with read-only access to two harmless things. That's a contained blast radius — and that's the entire goal."

💻 **Optional, if time:** run the full denial suite:
```bash
./scripts/03-negative-tests.sh
```
✅ Five checks, all should read **PASS** (a `Forbidden` is a pass).

❓ **Ask the room:** "What did we *not* have to do to make this safe?" (Answer: no firewalls, no extra tools — just a tight Role and no unnecessary token.)

---

## 32:00–35:00 — Production recap

🎯 **Goal:** turn the demo into rules they'll apply.

🗣 **Say — "Four habits and you've got 90% of this":**
1. **One badge per app.** Don't share, don't lean on `default`.
2. **Least privilege.** Grant the narrowest Role that lets the app work — down to a single named object when you can.
3. **No token if it doesn't call the API.** `automountServiceAccountToken: false`. Most apps qualify.
4. **Check before you ship.** `kubectl auth can-i --as=...`.

🗣 **Repeat the one sentence:**
> "Every pod has an identity — give each workload its own, grant only what it needs, and don't hand it a key if it never opens the door."

🗣 **Point them at the lab:**
> "Everything I ran is in this folder with a README. Clone it, break it, change the Role and watch `can-i` flip. Best way to learn it."

---

## 35:00–45:00 — Q&A (prepared answers)

**"Isn't the `default` account fine since it can't do anything?"**
Often yes on a fresh cluster — but teams add permissions to `default` over time and forget, so every pod silently inherits them. Naming a dedicated badge per app avoids that trap.

**"How is this different from a normal user account?"**
Users are for humans (you, via `kubectl`). ServiceAccounts are for workloads (pods). Same RBAC rules apply to both.

**"Do I have to write all this YAML by hand?"**
For learning, yes. In production most of it comes from Helm charts or operators — but you still review the Role they ship, because charts often ask for more than they need.

**"What about giving an app access to AWS/GCP/Azure?"**
You link its ServiceAccount to a cloud identity so it gets short-lived cloud credentials automatically — no cloud keys stored in the cluster. See `reference/cloud-iam-serviceaccounts.yml`. (Deep-dive below.)

**"Is the token safe once it's mounted?"**
Modern tokens (Kubernetes 1.24+) expire and rotate automatically, and can be scoped so they're only valid for the API server. Much safer than the old never-expiring ones. (Deep-dive below.)

**"How do I audit what already exists?"**
`kubectl auth can-i --list --as=system:serviceaccount:<ns>:<name>`, and community tools like `kubectl-who-can` and `rbac-lookup`.

---

## Optional deep-dives (only if an advanced person asks)

Skip these for a gentle room — they're here so a sharp question doesn't derail you.

- **Short-lived projected tokens.** The `reporter` mounts its token via a `projected` volume with `expirationSeconds: 3600` and an `audience`. This gives a token that auto-rotates and only works against the API server. Since 1.24 the default auto-mounted token already behaves this way; the manifest just makes it explicit. (`manifests/25-reporter-deployment.yml`)
- **`resourceNames` limitation.** You can scope `get`/`update`/`patch`/`delete` to specific object names, but **not** `list`/`watch` — RBAC can't "list a subset by name." That's why the reporter *gets* its ConfigMap by name instead of listing. (`manifests/21-reporter-role.yml`)
- **Pod Security Admission.** The namespace enforces the `restricted` profile, which is why every pod must run non-root with dropped capabilities. It's a separate control from RBAC but complements it. (`manifests/00-namespace.yml`)
- **Cloud IAM bridge.** IRSA (EKS), Workload Identity (GKE), Workload Identity (AKS) — annotation-only patterns in `reference/cloud-iam-serviceaccounts.yml`. Each needs cloud-side trust setup, so don't apply it locally.

---

## Facilitator cheat-strip (keep this beside you)

```bash
# DEPLOY
kubectl apply -f manifests/
kubectl -n acme-prod rollout status deploy/reporter
kubectl -n acme-prod get sa,role,rolebinding,deploy

# IT WORKS
kubectl -n acme-prod logs deploy/reporter -f            # Ctrl-C after a cycle
kubectl -n acme-prod exec deploy/web-app -- ls /var/run/secrets/kubernetes.io/serviceaccount

# CAN (yes)
kubectl auth can-i list pods                   --as=system:serviceaccount:acme-prod:reporter -n acme-prod
kubectl auth can-i get configmaps/app-config   --as=system:serviceaccount:acme-prod:reporter -n acme-prod

# CAN'T (no)
kubectl auth can-i get secrets                 --as=system:serviceaccount:acme-prod:reporter -n acme-prod
kubectl auth can-i get configmaps/other-config --as=system:serviceaccount:acme-prod:reporter -n acme-prod
kubectl auth can-i delete pods                 --as=system:serviceaccount:acme-prod:reporter -n acme-prod
kubectl -n acme-prod exec deploy/reporter -- kubectl get secret app-secret   # Forbidden

# FULL DENIAL SUITE (all PASS)
./scripts/03-negative-tests.sh

# RESET / SAFETY NET
./scripts/01-setup.sh      # if live deploy misbehaves
./scripts/99-cleanup.sh    # after the session
```

---

*Fits 30–45 min. For a 15-min lightning version: keep 5:00–11:00 (model), 14:00–22:00 (deploy + no-token), and 26:00–32:00 (denials); drop the rest.*
