# Kubernetes Namespaces & Cross‑Namespace DNS — Hands‑On Lab

Namespaces slice one cluster into isolated "virtual clusters." This lab runs the
*same* app (`webapp` + `web-service`) in three namespaces at once, proving that
names only collide *within* a namespace — and then teaches the exact DNS rule
for reaching a Service in any namespace from anywhere.

By the end you will be able to:

- Explain what a namespace is and what it does (and doesn't) isolate.
- Tell namespaced resources apart from cluster‑scoped ones.
- Address any Service by its full DNS name and its short forms.
- Move between namespaces with `kubectl` without retyping `-n` every time.
- Cap a namespace's resource usage with a ResourceQuota + LimitRange.

---

## 1. What a namespace is

A namespace is a scope for **names** and a handle for **policy**. Two things
follow from that:

- **Names are unique per namespace, not per cluster.** A Pod called `webapp` can
  exist in `default`, `dev`, and `prod` simultaneously — that's the entire point
  of this lab.
- **Policy attaches to namespaces.** RBAC roles, resource quotas, limit ranges,
  and network policies are all applied per namespace, which is why teams and
  environments are usually split this way.

What a namespace is **not**: a network firewall. By default a Pod in `dev` can
freely reach a Service in `prod` over DNS (you'll do exactly that below). Real
traffic isolation needs a **NetworkPolicy** — see §9.

---

## 2. Namespaced vs cluster‑scoped resources

Not everything lives in a namespace.

| Namespaced (live inside one) | Cluster‑scoped (no namespace) |
|---|---|
| Pod, Service, Deployment, ReplicaSet | Node |
| ConfigMap, Secret, PVC | PersistentVolume, StorageClass |
| Role, RoleBinding | ClusterRole, ClusterRoleBinding |
| ResourceQuota, LimitRange | **Namespace itself** |

See the full split on your cluster:

```bash
kubectl api-resources --namespaced=true
kubectl api-resources --namespaced=false
```

---

## 3. Apply the lab

```bash
kubectl apply -f 01-namespaces.yaml
kubectl apply -f 02-webapp-default.yaml
kubectl apply -f 03-webapp-dev.yaml
kubectl apply -f 04-webapp-prod.yaml

kubectl get pods,svc -A -l app=webapp     # -A / --all-namespaces: see all three
```

You now have three identically‑named `web-service` Services, one per namespace,
each fronting a Pod that echoes a different message.

---

## 4. Working across namespaces with `kubectl`

```bash
kubectl get pods                       # only the CURRENT namespace (default)
kubectl get pods -n dev                # a specific namespace
kubectl get pods --all-namespaces      # everything, everywhere (or: -A)
kubectl get all -n prod                # the common objects in prod
```

Tired of typing `-n dev`? Change your context's default namespace:

```bash
kubectl config set-context --current --namespace=dev
kubectl get pods                       # now defaults to dev
kubectl config set-context --current --namespace=default   # switch back
```

> This is also the answer to "why did my object land in the wrong namespace?" —
> a manifest with no `namespace:` field uses whatever your context is set to,
> not necessarily `default`.

---

## 5. The DNS rule (the heart of this lab)

Every Service gets a DNS name of the form:

```
<service-name>.<namespace>.svc.cluster.local
```

So our three Services are:

```
web-service.default.svc.cluster.local
web-service.dev.svc.cluster.local
web-service.prod.svc.cluster.local
```

Kubernetes also accepts **short forms**, resolved using the search domains in
every Pod's `/etc/resolv.conf`:

| You type… | Resolves to… | Works from… |
|---|---|---|
| `web-service` | Service in the **caller's own** namespace | same namespace only |
| `web-service.prod` | `web-service` in `prod` | anywhere |
| `web-service.prod.svc` | same as above | anywhere |
| `web-service.prod.svc.cluster.local` | fully qualified, unambiguous | anywhere |

The lesson: **a bare name is namespace‑relative.** To reach another namespace
you must add at least `.<namespace>`.

---

## 6. Verify it — from a throwaway Pod

Launch an interactive Pod and call each Service. (Run it in `default` unless you
say otherwise.)

```bash
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- sh
```

Inside the Pod:

```sh
# Full names always work, from any namespace:
curl web-service.default.svc.cluster.local:5678   # -> Hello From DEFAULT
curl web-service.dev.svc.cluster.local:5678       # -> Hello From DEV
curl web-service.prod.svc.cluster.local:5678      # -> Hello From PROD

# Short name = the caller's namespace (this Pod is in default):
curl web-service:5678                              # -> Hello From DEFAULT

# See the ClusterIP behind a name, and why short names work:
nslookup web-service.dev.svc.cluster.local
cat /etc/resolv.conf                               # note the "search" domains
```

Now prove the short name is relative. Exit, and launch the same Pod **in dev**:

```bash
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -n dev -- sh
```

```sh
curl web-service:5678         # -> Hello From DEV   (same name, different result!)
curl web-service.prod:5678    # -> Hello From PROD  (reach across with .prod)
```

Same command, `web-service:5678`, returns DEV from a dev Pod and DEFAULT from a
default Pod. That single observation is the whole DNS model in a nutshell.

---

## 7. BONUS — capping a namespace (`05-quota-and-limits.yaml`)

```bash
kubectl apply -f 05-quota-and-limits.yaml
kubectl replace --force -f 03-webapp-dev.yaml    # recreate dev webapp under the quota
kubectl get pod webapp -n dev \
  -o jsonpath='{.spec.containers[0].resources}{"\n"}'   # inherited the defaults
kubectl describe resourcequota dev-quota -n dev  # Used vs Hard
```

Two teaching points:

- The webapp Pod declares **no** requests/limits, yet it now has them — the
  **LimitRange** injected the defaults on admission.
- Without that LimitRange, the same Pod would be **rejected**, because once a
  ResourceQuota governs `requests.*`/`limits.*`, every Pod must specify them.
  Quota and LimitRange are a pair.

---

## 8. Cleaning up — and the namespace superpower

Deleting a namespace deletes **everything inside it**, in one command:

```bash
kubectl delete namespace dev
kubectl delete namespace prod
```

That cascade is a feature (tear down a whole environment instantly) and a foot‑
gun (there is no undo). For the objects in `default` (which you should not
delete as a namespace):

```bash
kubectl delete -f 02-webapp-default.yaml --ignore-not-found
kubectl delete pod curl --ignore-not-found
```

---

## 9. Gotchas & troubleshooting

- **Namespaces don't isolate traffic.** Any Pod can curl any Service across
  namespaces by default. To block it, apply a **NetworkPolicy** (requires a CNI
  that enforces them, e.g. Calico, Cilium).
- **A Service never selects Pods in another namespace.** Selectors are
  namespace‑local; `web-service` in `prod` can only front Pods in `prod`.
- **"It worked from one Pod but not another."** You used a short name — it's
  relative to the *caller's* namespace. Use `.<namespace>` or the FQDN.
- **Object went to the wrong namespace.** Your context's default namespace isn't
  what you thought. Check with
  `kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'`.
- **`kubectl delete ns` hangs in `Terminating`.** Something inside has a
  finalizer that isn't completing; inspect with
  `kubectl get all,pvc -n <ns>` before force‑removing finalizers.
- **Can't set `namespace:` on a Namespace/Node/PV.** They're cluster‑scoped;
  the field is meaningless there.

---

### One‑line summary to leave students with

> A namespace scopes **names** and **policy**, not the network: the same
> `web-service` can live in every namespace, and you reach a specific one with
> `web-service.<namespace>.svc.cluster.local` — where a bare `web-service` always
> means "the one in my own namespace."
