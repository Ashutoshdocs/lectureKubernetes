# PV, PVC & StorageClass — A Hands-On Demo

Learn how storage binds in Kubernetes by running three cases and watching the
difference. Covers the theory of **static vs dynamic provisioning** and the three
behaviors of `storageClassName`.

Files in this demo:
- `case-a-dynamic-default.yaml` — omitted class → dynamic
- `case-b-static-empty.yaml` — `""` → static
- `case-c-named-class.yaml` — `"name"` → dynamic **and** static

---

## 1. The three building blocks

| Object | What it is | Who usually writes it |
|--------|-----------|-----------------------|
| **PersistentVolume (PV)** | A real piece of storage in the cluster (a disk, an NFS share, a hostPath dir). | You (static) *or* a provisioner (dynamic) |
| **PersistentVolumeClaim (PVC)** | A *request* for storage ("I need 1Gi, RWO"). Pods use this, never the PV directly. | You |
| **StorageClass (SC)** | A *recipe* for auto-building PVs on demand. Names a `provisioner`. | Cluster admin / cloud provider |

Mental model:

```
Pod  ->  PVC (the request)  ->  PV (the actual storage)
                                 ^
                                 |
                       StorageClass builds this
                       automatically (dynamic only)
```

A pod always mounts a **PVC**. The PVC binds to a **PV**. How that PV comes into
existence is the whole story below.

---

## 2. Static vs Dynamic provisioning

### Static provisioning
**You create the PV by hand** ahead of time. The PVC then finds and binds to it.
No StorageClass involved.

```
You write PV  +  You write PVC   ->  Kubernetes matches & binds them
```

Good for: pre-existing disks, NFS exports, hostPath, learning, tight control.

### Dynamic provisioning
**You only write the PVC.** A StorageClass's `provisioner` creates the PV for you
automatically, then binds it.

```
You write PVC (with a class)  ->  provisioner creates PV  ->  auto-bind
```

Good for: clouds (EBS/PD/Azure Disk), scale, not wanting to pre-make volumes.

> The single fact that decides which one you get is the PVC's `storageClassName`.

---

## 3. The three behaviors of `storageClassName`

| PVC `storageClassName` | Meaning | Result |
|------------------------|---------|--------|
| **omitted entirely** | "use the **default** StorageClass" | Dynamically provisions a NEW PV |
| **`""`** (empty string) | "**no** class, **no** dynamic provisioning" | Binds only to a static PV that also has `""` |
| **`"some-name"`** | "use this specific class" | Provisions via that class, **or** binds a PV of that class |

**Key trap:** *omitted ≠ empty string.*
- Leaving the field out = "please build me one from the default."
- `""` = "hands off, bind me to a PV I already made."

Check your default before starting:
```bash
kubectl get sc
# the row marked (default) is what an omitted class will use
```

---

## 4. DEMO — run the three cases

Start clean each time so results are unambiguous.

### ▶ Case A — omitted → DYNAMIC (default class)

```bash
kubectl apply -f case-a-dynamic-default.yaml
kubectl get pv,pvc
```

What you'll see: a PV **you never wrote** appears, named `pvc-<uuid>`, `Bound` to
`case-a-pvc`, `StorageClass` = your default (e.g. `local-path`).

```bash
# proof it was auto-made:
kubectl describe pvc case-a-pvc | grep -i provision
kubectl get pv <pvc-uuid-name> -o jsonpath='{.metadata.annotations}'
#   -> pv.kubernetes.io/provisioned-by: rancher.io/local-path
```

Takeaway: **no PV in the file, yet a PV exists** — the default class built it.

Cleanup:
```bash
kubectl delete -f case-a-dynamic-default.yaml
# reclaimPolicy Delete -> the auto PV disappears with the PVC
```

---

### ▶ Case B — `""` → STATIC binding

```bash
kubectl apply -f case-b-static-empty.yaml
kubectl get pv,pvc
```

What you'll see: `case-b-pvc` binds to **your** `case-b-pv`. **No** `pvc-<uuid>`
is created — dynamic provisioning was switched off by `""`.

```bash
kubectl get pvc case-b-pvc -o jsonpath='{.spec.volumeName}{"\n"}'
#   -> case-b-pv
```

Try the mistake on purpose: delete the `storageClassName: ""` line from the PVC
and re-apply into a fresh namespace — you'll get a `pvc-<uuid>` instead and
`case-b-pv` stays `Available`. That's the exact bug from the original lab.

Cleanup:
```bash
kubectl delete -f case-b-static-empty.yaml
# reclaimPolicy Retain -> the PV goes to Released; delete it manually if desired
kubectl delete pv case-b-pv
```

---

### ▶ Case C — `"name"` → DYNAMIC *and* STATIC

This file has two independent parts.

```bash
kubectl apply -f case-c-named-class.yaml
kubectl get pv,pvc
```

- **C1 (`storageClassName: local-path`)** → a real provisioner exists for that
  name, so a fresh `pvc-<uuid>` PV is **dynamically** created for `case-c1-pvc`.
- **C2 (`storageClassName: manual`)** → the `manual` class uses
  `no-provisioner`, so it **cannot** build anything; `case-c2-pvc` instead binds
  **statically** to the hand-made `case-c2-pv` that carries the same class name.

```bash
kubectl get pvc case-c1-pvc -o jsonpath='{.spec.volumeName}{"\n"}'  # pvc-<uuid>
kubectl get pvc case-c2-pvc -o jsonpath='{.spec.volumeName}{"\n"}'  # case-c2-pv
```

Takeaway: a **named class** does whichever its provisioner allows — build a new
PV, or just act as a label that groups your static PVs.

Cleanup:
```bash
kubectl delete -f case-c-named-class.yaml
kubectl delete pv case-c2-pv 2>/dev/null   # Retain leaves it behind
```

---

## 5. Decision flow (cheat sheet)

```
Do you want Kubernetes to create the volume for you?
│
├── YES (dynamic)
│     ├── happy with the default class?  -> omit storageClassName
│     └── want a specific class?         -> storageClassName: "<name>"
│
└── NO (static, you made the PV)
      ├── your PV has no class            -> storageClassName: ""
      └── your PV has a class label       -> storageClassName: "<same-name>"
```

---

## 6. Verify anything

```bash
kubectl get sc                       # classes; which is (default)
kubectl get pv,pvc -o wide           # names + class + bound status
kubectl describe pvc <name>          # events reveal the provisioner
kubectl describe pv  <name>          # source, reclaim policy, node affinity
```

**How to tell static from dynamic at a glance:**
- Dynamic PV → name is `pvc-<uuid>`, has a `provisioned-by` annotation.
- Static PV → name is whatever *you* called it; you can see it in your YAML.

---

## 7. One-line summary
`storageClassName` is the steering wheel: **omit it** and the default class builds
a volume for you; set **`""`** to bind a volume you made yourself; set a
**name** to pick a specific class (which either provisions or just labels).
