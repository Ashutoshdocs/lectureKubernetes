# VM → Docker → Kubernetes: Complete Teaching Demo

## Goal

This practical deliberately demonstrates **three different problems** in sequence:

```text
VM
 ↓
Shared dependency environment
 ↓
❌ App 2 changes App 1's dependencies
 ↓
Docker
 ↓
✅ Dependency isolation
 ↓
But lifecycle/scaling/update are manual
 ↓
Kubernetes
 ↓
✅ Desired state + reconciliation + self-healing + scaling + rolling update + rollback
```

---

# 0. Prerequisites

Recommended:

- Ubuntu/Debian VM
- Python 3.10+
- Docker
- kubectl
- minikube or kind for a local Kubernetes cluster

Check:

```bash
python3 --version
docker --version
kubectl version --client
```

---

# PART 1 — VM: FORCE A REAL DEPENDENCY FAILURE

## Why this example is intentional

BlueForge requires:

```text
Jinja2==2.11.3
MarkupSafe==2.0.1
```

BlueForge deliberately imports:

```python
from markupsafe import soft_unicode
```

`soft_unicode` existed in the old MarkupSafe API.

GreenPulse requires:

```text
Jinja2==3.1.6
MarkupSafe==3.0.3
```

Modern MarkupSafe does not provide `soft_unicode`.

Therefore:

```text
BlueForge
    ↓
old dependency stack
    ↓
works

Install GreenPulse
    ↓
shared environment is upgraded
    ↓
MarkupSafe 2.0.1 → 3.0.3
    ↓
BlueForge
    ↓
❌ ImportError
```

This is deliberate. It gives the classroom a guaranteed visible failure.

---

## Step 1 — Create the shared VM environment

```bash
cd 01-vm-two-apps

python3 -m venv shared-env
source shared-env/bin/activate
```

---

## Step 2 — Install App 1

```bash
pip install -r app1/requirements.txt
```

Verify:

```bash
pip freeze | grep -E "Jinja|Markup"
```

Expected:

```text
Jinja2==2.11.3
MarkupSafe==2.0.1
```

Run:

```bash
python3 app1/app.py
```

Open:

```text
http://<VM-IP>:8080
```

### Expected

BlueForge page appears.

---

## Step 3 — Stop App 1

```text
CTRL+C
```

---

# Step 4 — Install App 2 into THE SAME ENVIRONMENT

```bash
pip install -r app2/requirements.txt
```

Pip changes the shared environment.

Verify:

```bash
pip freeze | grep -E "Jinja|Markup"
```

Expected:

```text
Jinja2==3.1.6
MarkupSafe==3.0.3
```

---

# Step 5 — Run App 2

```bash
python3 app2/app.py
```

Open:

```text
http://<VM-IP>:8080
```

### Expected

GreenPulse works.

---

# Step 6 — THE FAILURE

Stop GreenPulse:

```text
CTRL+C
```

Now run the application that originally required the old environment:

```bash
python3 app1/app.py
```

### Expected failure

You should get an error similar to:

```text
ImportError: cannot import name 'soft_unicode' from 'markupsafe'
```

This is the important demonstration.

---

# Explain the failure

App 1 originally had:

```text
Jinja2       2.11.3
MarkupSafe   2.0.1
```

Then App 2 was installed:

```text
Jinja2       3.1.6
MarkupSafe   3.0.3
```

But App 1 still expects its original dependency environment.

The VM itself is fine.

The operating system is fine.

The applications are not necessarily wrong.

The problem is:

```text
TWO APPLICATIONS
        ↓
ONE SHARED DEPENDENCY ENVIRONMENT
        ↓
DEPENDENCY VERSION COLLISION
```

---

# The question for students

Ask:

> Can one VM run two applications?

**Yes.**

Ask:

> Can two arbitrary applications safely share one dependency environment?

**No.**

Ask:

> How do we isolate their application environments?

**Containers.**

---

# PART 2 — DOCKER

Go to:

```bash
cd ../02-docker-two-apps
```

Now each application gets its own image.

```text
                   VM
                    |
                 Docker
                /      \
               /        \
       BlueForge      GreenPulse
       container      container
          |               |
     Jinja 2.11.3    Jinja 3.1.6
     MarkupSafe 2.0  MarkupSafe 3.0
```

---

## Step 1 — Build BlueForge

```bash
docker build -t blueforge:v1 ./app1
```

Verify its dependencies:

```bash
docker run --rm blueforge:v1 \
  python -c "import jinja2, markupsafe; print(jinja2.__version__, markupsafe.__version__)"
```

Expected:

```text
2.11.3 2.0.1
```

---

## Step 2 — Build GreenPulse

```bash
docker build -t greenpulse:v1 ./app2
```

Verify:

```bash
docker run --rm greenpulse:v1 \
  python -c "import jinja2, markupsafe; print(jinja2.__version__, markupsafe.__version__)"
```

Expected:

```text
3.1.6 3.0.3
```

---

# This is the Docker proof

Both containers contain different versions:

```text
BlueForge
  Jinja2      2.11.3
  MarkupSafe  2.0.1

GreenPulse
  Jinja2      3.1.6
  MarkupSafe  3.0.3
```

They coexist on the same VM.

---

## Step 3 — Run both

```bash
docker run -d \
  --name blueforge \
  -p 8081:8080 \
  blueforge:v1
```

```bash
docker run -d \
  --name greenpulse \
  -p 8082:8080 \
  greenpulse:v1
```

Open:

```text
http://<VM-IP>:8080
http://<VM-IP>:8081
```

Both work.

---

# Important transition

Docker solved:

> **"How do I keep application environments isolated?"**

But now ask:

> "Who watches the containers?"

Kill BlueForge:

```bash
docker kill blueforge
```

Check:

```bash
docker ps
```

BlueForge is gone.

Restart:

```bash
docker start blueforge
```

Ask students:

> Who detected the failure?

Human.

> Who restarted it?

Human.

Then ask:

> What if I need 5 replicas?

> What if I need a rolling update?

> What if one instance dies at 3 AM?

> What if I need rollback?

This leads naturally to Kubernetes.

---

# PART 3 — KUBERNETES

Go to:

```bash
cd ../03-k8s
```

Build:

```bash
docker save  blueforge:v1 -o  blueforge:v1.tar
docker save greenpulse:v1 -o greenpulse:v1.tar


sudo ctr -n=k8s.io images import  blueforge:v1.tar
sudo ctr -n=k8s.io images import greenpulse:v1.tar
```



---

# Step 1 — Create Deployment

```bash
kubectl apply -f k8s/deployment.yaml
```

The important declaration is:

```yaml
replicas: 3
```

Check:

```bash
kubectl get deployment
kubectl get pods
```

You should see 3 Pods.

---

# The key conceptual difference

Docker:

```text
docker run
```

means:

> Start this container.

Kubernetes:

```yaml
replicas: 3
```

means:

> **Keep three instances of this application running.**

That is the major conceptual jump.

---

# Step 2 — Create Service

```bash
kubectl apply -f k8s/service.yaml
```

Check:

```bash
kubectl get svc
```

For a local cluster:

```bash
kubectl port-forward service/blueforge 8080:80
```

Open:

```text
http://127.0.0.1:8080
```

---

# PART 4 — SELF HEALING

Get the Pods:

```bash
kubectl get pods
```

Delete one:

```bash
kubectl delete pod <pod-name>
```

Watch:

```bash
kubectl get pods -w
```

A replacement appears.

---

# Explain what happened

Before:

```text
Desired = 3
Actual  = 3
```

After deletion:

```text
Desired = 3
Actual  = 2
```

Kubernetes controller notices:

```text
Desired != Actual
```

It creates a replacement:

```text
Desired = 3
Actual  = 3
```

This is:

# Reconciliation

---

# PART 5 — SCALE

Scale:

```bash
kubectl scale deployment blueforge --replicas=5
```

Watch:

```bash
kubectl get pods -w
```

Kubernetes creates the additional Pods.

Scale down:

```bash
kubectl scale deployment blueforge --replicas=2
```

Kubernetes removes the excess Pods.

---

# PART 6 — ROLLING UPDATE

Build v2:

```bash
docker build -t blueforge:v2 ./app
```

Load into minikube:

```bash
minikube image load blueforge:v2
```

or kind:

```bash
kind load docker-image blueforge:v2
```

Update:

```bash
kubectl set image deployment/blueforge blueforge=blueforge:v2
```

Watch:

```bash
kubectl get pods -w
```

Check:

```bash
kubectl rollout status deployment/blueforge
```

Kubernetes replaces Pods using the Deployment's rolling-update strategy.

---

# PART 7 — ROLLBACK

Show history:

```bash
kubectl rollout history deployment/blueforge
```

Rollback:

```bash
kubectl rollout undo deployment/blueforge
```

Then:

```bash
kubectl rollout status deployment/blueforge
```

---

# Final classroom comparison

| Capability | Shared VM | Docker | Kubernetes |
|---|---:|---:|---:|
| Run multiple apps | ✅ | ✅ | ✅ |
| Isolate dependencies | ❌ | ✅ | ✅ |
| Independent application environments | ❌ | ✅ | ✅ |
| Automatic replacement | ❌ | Manual | ✅ |
| Desired replica count | ❌ | Manual | ✅ |
| Scaling | Manual | Manual | ✅ |
| Rolling updates | Manual | Manual | ✅ |
| Rollback | Manual | Manual | ✅ |
| Stable Service endpoint | Manual | Manual | ✅ |
| Reconciliation | ❌ | ❌ | ✅ |

---

# Final mental model

## VM

```text
WHERE does my application run?
```

## Docker

```text
HOW do I package and isolate my application?
```

## Kubernetes

```text
HOW do I continuously operate the application?
```

---

# One sentence to end the lecture

> **A VM gives you infrastructure, Docker gives you application isolation, and Kubernetes gives you declarative application operations.**

---

# Cleanup

```bash
kubectl delete -f 03-k8s/k8s/service.yaml
kubectl delete -f 03-k8s/k8s/deployment.yaml

docker rm -f blueforge greenpulse 2>/dev/null || true

rm -rf 01-vm-two-apps/shared-env
```
