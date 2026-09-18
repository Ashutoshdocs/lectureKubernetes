# Kubernetes Init Containers — Three Hands-On Demos

**Init containers** run **before** your app containers, **in order**, and each must **finish
successfully** before the next one — and finally the main app — starts. They're how you do
setup work that must happen *first*: generate config, wait for a dependency, verify
prerequisites.

This repo has three demos, each teaching a different real use of init containers:

| Demo | File | Teaches |
|------|------|---------|
| 1. Wait for a **script** | `01-init-script.yml` | An init container runs a setup script; the app starts only after it finishes. |
| 2. Wait for **another pod** | `02-wait-for-pod.yml` + `mysql-deployment.yml` | An init container blocks until MySQL is reachable. |
| 3. **Three** init containers (prod-style) | `03-three-init-prod.yml` | Ordered multi-step setup with resource limits and probes. |

---

## How init containers work (the mental model)

- They run **sequentially**, one at a time, in the order listed.
- Each must **exit 0** before the next starts. If one fails, Kubernetes **restarts that init
  container** (per the pod's `restartPolicy`) and the app containers **never start** until it
  passes.
- While init containers run, the pod status shows **`Init:0/N`, `Init:1/N`, …**
- They can share data with the app through a **volume** (an `emptyDir` here).
- Common uses: **generate config**, **wait for a dependency** (DB, API, another service),
  **run migrations**, **verify prerequisites**.

```
Pod start ─▶ initContainer[0] ─▶ initContainer[1] ─▶ … ─▶ app containers start
              (must exit 0)        (must exit 0)
```

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.
- For NodePort access in Demo 3: a node IP, or `minikube service ... --url`.

---

# Demo 1 — Wait for a script to run

**File:** `01-init-script.yml`

An init container (`prepare-content`) runs a script that writes an HTML page to a shared
volume and sleeps a few seconds to simulate setup work. The `nginx` container starts **only
after** that script finishes, and serves the file the init container produced.

### Steps

**1. Apply the pod**
```bash
kubectl apply -f 01-init-script.yml
```

**2. Watch the init phase (this is the whole point)**
```bash
kubectl get pod init-script-demo -w
```
Expected — it sits in `Init:0/1` while the script runs, then flips to `Running`:
```
NAME               READY   STATUS     RESTARTS   AGE
init-script-demo   0/1     Init:0/1   0          3s
init-script-demo   1/1     Running    0          8s
```

**3. Read the init container's logs**
```bash
kubectl logs init-script-demo -c prepare-content
# [init] Preparing web content...
# [init] Content ready.
```

**4. Confirm the app is serving what the init container made**
```bash
kubectl exec init-script-demo -c nginx -- cat /usr/share/nginx/html/index.html
```
You'll see the "Welcome from the Init Container" page. ✅

**5. Clean up**
```bash
kubectl delete -f 01-init-script.yml
```

---

# Demo 2 — Wait for another pod to come up

**Files:** `02-wait-for-pod.yml` and `mysql-deployment.yml`

The init container (`wait-for-mysql`) loops `nc -z mysql 3306` until the MySQL Service
answers. The main app stays unstarted until then. This is the classic pattern for **"don't
start my app until its database is ready."**

### Steps — first prove the wait, THEN release it

**1. Start the app WITHOUT MySQL (so you can watch it block)**
```bash
kubectl apply -f 02-wait-for-pod.yml
kubectl get pod app-with-init -w
```
Expected — it stays stuck in `Init:0/1` because MySQL doesn't exist yet:
```
NAME            READY   STATUS     RESTARTS   AGE
app-with-init   0/1     Init:0/1   0          20s
```

**2. See what it's waiting on**
```bash
kubectl logs app-with-init -c wait-for-mysql
# [init] Waiting for MySQL to be reachable at mysql:3306...
# [init] MySQL not up yet - retrying in 2s...
```

**3. Now deploy MySQL**
```bash
kubectl apply -f mysql-deployment.yml
```

**4. Watch the app unblock**
Within a few seconds of MySQL becoming reachable, the init container exits and the app starts:
```bash
kubectl get pod app-with-init -w
# app-with-init   1/1   Running
kubectl logs app-with-init -c main-app
# [app] Connected to MySQL and starting app...
```
✅ The init container gated the app on a dependency being live.

**5. Clean up**
```bash
kubectl delete -f 02-wait-for-pod.yml
kubectl delete -f mysql-deployment.yml
```

---

# Demo 3 — Three init containers (production-style)

**File:** `03-three-init-prod.yml`

Three init containers run **in order**, each writing to a shared `/app` volume:

1. `init-download-config` — writes `app.env` (the app config).
2. `init-db-setup` — simulates a DB check, writes `db_status.txt`.
3. `init-verify-dependencies` — installs/verifies Flask, writes `deps.txt`.

Only after **all three** succeed do the two app containers start: an **nginx** frontend
(`:80`) and a **Flask** app (`:5000`) that reads the config the init containers produced.

**What makes it "production-style":** every container has **resource `requests`/`limits`**,
pinned image tags, `imagePullPolicy: IfNotPresent`, and the app containers have
**readiness/liveness probes**.

### Steps

**1. Apply the pod**
```bash
kubectl apply -f 03-three-init-prod.yml
```

**2. Watch the init containers progress one by one**
```bash
kubectl get pod nginx-python-init-demo -w
```
Expected — the counter climbs as each init container completes:
```
STATUS
Init:0/3
Init:1/3
Init:2/3
PodInitializing
Running
```

**3. Read each init container's logs (in order)**
```bash
kubectl logs nginx-python-init-demo -c init-download-config
kubectl logs nginx-python-init-demo -c init-db-setup
kubectl logs nginx-python-init-demo -c init-verify-dependencies
```

**4. Confirm the init output landed on the shared volume**
```bash
kubectl exec nginx-python-init-demo -c nginx -- ls -l /usr/share/nginx/html
kubectl exec nginx-python-init-demo -c python-app -- ls -l /app/config
# app.env  db_status.txt  deps.txt
```

**5. Expose BOTH app containers over NodePort**
(from `expose_over_node_port_for_3init_yaml.txt`)
```bash
kubectl expose pod nginx-python-init-demo \
  --type=NodePort --port=80 --target-port=80 --name=nginx-python-service

kubectl expose pod nginx-python-init-demo \
  --type=NodePort --port=5000 --target-port=5000 --name=flask-service
```

**6. Find the assigned NodePorts and hit them**
```bash
kubectl get svc nginx-python-service flask-service
```
```bash
curl http://<NodeIP>:<nginx-nodePort>    # → Welcome to Nginx Frontend
curl http://<NodeIP>:<flask-nodePort>    # → Hello from Flask App! Configs: APP_ENV=production
```
> **minikube:** `minikube service flask-service --url` (and same for nginx) gives reachable URLs.
> The Flask response includes the config **written by init container #1**, proving the init
> phase fed the app.

**7. Clean up**
```bash
kubectl delete svc nginx-python-service flask-service
kubectl delete -f 03-three-init-prod.yml
```

---

## Debugging init containers (handy anytime)

```bash
# Overall phase + which init step it's on
kubectl get pod <pod> -w

# Why an init container is stuck or failing
kubectl describe pod <pod>          # see Events + init container statuses

# Logs of a SPECIFIC init container (must use -c)
kubectl logs <pod> -c <init-container-name>

# Follow logs live
kubectl logs -f <pod> -c <init-container-name>
```
A pod stuck in `Init:0/N` almost always means an init container is **waiting** (Demo 2) or
**crash-looping** — `describe` and its logs tell you which.

---

## Key takeaways

- Init containers run **before** app containers, **in order**, each to **success**.
- Use them to **wait for a script/setup** (Demo 1), **wait for a dependency** (Demo 2), or
  chain **multiple ordered setup steps** (Demo 3).
- They share data with the app via a **volume** (`emptyDir` here).
- Pod status `Init:x/N` shows progress; a stuck pod means an init step hasn't passed.
- Production init containers get the same treatment as app containers: **resource limits**,
  **pinned images**, and the app gets **probes**.

> **Prod note:** installing packages at runtime (`pip install flask`) is done here for a
> self-contained demo. In production you'd **bake dependencies into the image** instead, and
> keep secrets like the MySQL password in a **Secret**, not inline YAML.
