# ConfigMap Update Demo: Volume vs subPath, and the Kustomize Fix

This is a hands-on demo you can run on any Kubernetes cluster (minikube, kind,
Docker Desktop, or a real one). It proves two things you can *see* with your own
eyes:

1. **A ConfigMap mounted as a folder (volume) updates automatically** when you
   change it.
2. **The same ConfigMap mounted with `subPath` does NOT update** — it stays
   frozen.

Then it shows **how Kustomize solves the bigger problem**: making your app
actually pick up config changes by automatically restarting the Pods.

Everything is explained in plain language — no prior deep Kubernetes knowledge
assumed.

```
configmap issue & fix/
├── part1-mount-behavior/     # See volume-update vs subPath-frozen
│   ├── configmap.yaml            (theme = dark)
│   ├── configmap-updated.yaml    (theme = light)
│   └── pod.yaml                  (mounts both ways at once)
└── part2-kustomize-fix/      # See config change auto-restart Pods
    ├── kustomization.yaml
    └── deployment.yaml
```

---

## First, the mental model (read this once)

A **ConfigMap** is just a little box of settings living in the cluster, e.g.
`theme = dark`. Your Pod can read that box in different ways, and *the way it
reads it* decides whether updates reach it.

Two ways matter for this demo:

- **Mount as a folder (a plain volume mount).**
  Think of this as a **live window** into the box. Kubernetes keeps the window
  in sync with the box. Change the box → after a short delay, the window shows
  the new value. ✅ Auto-updates.

- **Mount one key with `subPath`.**
  Think of this as a **photocopy** you taped to the wall the moment the Pod
  started. It's a snapshot. Editing the original box later does nothing to your
  taped-up photocopy. ❌ Never updates (until the Pod is recreated).

> There's also a third way — reading config as **environment variables** — and
> those never update live either. This demo focuses on the two mount styles
> because that's where people get surprised.

---

## Prerequisites

- A running cluster and `kubectl` pointed at it.
- `kubectl version` for Kustomize is built in (`kubectl apply -k`), so no extra
  install needed.

---

# Part 1 — Watch a volume update and a subPath stay frozen

### Step 1: Create the ConfigMap and the Pod

```bash
cd part1-mount-behavior
kubectl apply -f configmap.yaml
kubectl apply -f pod.yaml
kubectl wait --for=condition=Ready pod/mount-demo --timeout=60s
```

The Pod (`pod.yaml`) mounts the **same** ConfigMap in **two ways at once**:

| Path inside the Pod | How it's mounted | Expectation |
|---|---|---|
| `/etc/config/theme`        | folder / volume mount | should update |
| `/etc/single/theme`        | `subPath` mount       | should stay frozen |

### Step 2: Check the starting values (both say `dark`)

```bash
kubectl exec mount-demo -- cat /etc/config/theme    # -> dark
kubectl exec mount-demo -- cat /etc/single/theme    # -> dark
```

### Step 3: Change the ConfigMap (`dark` → `light`)

Either apply the ready-made updated file:

```bash
kubectl apply -f configmap-updated.yaml
```

…or do it the "PRACTICAL02" one-liner way (dry-run + apply, in-place update):

```bash
kubectl create configmap web-config \
  --from-literal=theme=light --from-literal=title="My Web App" \
  -o yaml --dry-run=client | kubectl apply -f -
```

### Step 4: Wait for the sync, then look again

⚠️ **It is not instant.** Kubernetes syncs mounted files on a timer (roughly up
to a minute). If you check immediately you'll still see `dark`. Give it time:

```bash
sleep 90

kubectl exec mount-demo -- cat /etc/config/theme    # -> light   ✅ updated!
kubectl exec mount-demo -- cat /etc/single/theme    # -> dark    ❌ still frozen
```

### What just happened (in plain words)

- `/etc/config/theme` is the **live window** → it caught up to the new value.
- `/etc/single/theme` is the **taped-up photocopy** (subPath) → it never changed.

That single side-by-side result is the whole lesson of Part 1.

> **Important footnote:** even for the folder mount that *did* update, the file
> on disk changed — but a real running app that read the value once at startup
> would still be using the old value. Kubernetes updates the file; it does not
> tell your program to re-read it. That limitation is exactly what Part 2 fixes.

### Clean up Part 1

```bash
kubectl delete -f pod.yaml -f configmap.yaml
```

---

# Part 2 — Make a config change actually restart the Pods (Kustomize)

### The problem we're solving

Normally your Deployment holds a **sticky note** that says
*"use the config named `app-config`."* When you edit the *contents* of
`app-config`, the sticky note still says the exact same words — `app-config` —
so Kubernetes sees no change and **doesn't restart anything**. Your new settings
never take effect.

The fix that works: **give the config a brand-new name every time it changes**
(`app-config-v1`, `app-config-v2`, …) and update the sticky note. Now the note is
different, the Deployment looks different, and Kubernetes rolls out fresh Pods.

Doing that by hand is painful — you'd rename the ConfigMap *and* track down every
place that references it. **Kustomize automates exactly that chore.**

### What Kustomize does for you

Look at `kustomization.yaml`. Instead of writing a ConfigMap directly, you list
its values under `configMapGenerator`. When you run Kustomize, it:

1. reads the values,
2. adds a **hash of the contents** to the name → `app-config-6ct58987ht`
   (change a value → the hash changes → the name changes), and
3. **rewrites every reference** in your manifests to the new name automatically.

### Step 1: Deploy it

```bash
cd ../part2-kustomize-fix
kubectl apply -k .
```

See the generated, hashed ConfigMap name and the first rollout:

```bash
kubectl get configmap                       # note the app-config-<hash> name
kubectl rollout history deployment/web-app  # revision 1
```

### Step 2: Change a config value

Open `kustomization.yaml` and change `theme=dark` to `theme=light`.

### Step 3: Apply again — and watch the Pods roll

```bash
kubectl apply -k .

kubectl get configmap                       # a NEW app-config-<different-hash>
kubectl rollout status deployment/web-app   # a fresh rollout is happening
kubectl rollout history deployment/web-app  # revision 2  <-- Pods restarted!
```

### What just happened (in plain words)

You changed one value. Kustomize gave the ConfigMap a new hashed name and updated
the Deployment's sticky note to match. Because the Deployment now looks
different, Kubernetes did what it does best: rolled out new Pods that start up
reading the new config. **No manual restart, no forgotten step.**

### Compare: the old broken way

If instead you had run `kubectl edit configmap app-config` and changed the value
in place, `kubectl rollout history` would still show **revision 1** — nothing
would restart, because the name never changed. That's the trap this whole demo
is about.

### A small housekeeping note

`kubectl apply -k .` does **not** delete the old hashed ConfigMap by default, so
you'll see leftovers piling up. To clean them automatically as you go, use apply
with pruning, or just delete old ones by hand:

```bash
kubectl delete -k .        # removes the current Deployment + generated ConfigMap
kubectl get configmap      # delete any leftover app-config-* by name if needed
```

---

## The one-paragraph summary

A ConfigMap mounted as a **folder** updates on its own (after a short delay); the
same key mounted with **`subPath`** is a frozen snapshot and never updates. But
even an updated file doesn't help if your app read it only at startup — and
editing a ConfigMap in place never restarts Pods anyway. **Kustomize** fixes both
headaches by renaming the ConfigMap on every change and updating all references,
so Kubernetes automatically rolls out new Pods that boot up with the new config.
