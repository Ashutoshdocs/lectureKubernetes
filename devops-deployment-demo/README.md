# DevOps Deployment Demo — VM → Docker → Kubernetes

One tiny web app, deployed **three different ways**, so you can feel the
difference between running software on a plain virtual machine, inside a Docker
container, and on a Kubernetes cluster.

The app is a small Python/Flask service that shows its own **hostname**,
**deploy mode**, and a **visit counter**. That's the whole trick: refresh the
page and watch the hostname behave differently in each environment.

- On a **VM** → the hostname never changes (one machine).
- In **Docker** → the hostname is the container id.
- On **Kubernetes** (3 pods) → the hostname *changes between refreshes* as your
  requests get load-balanced across pods.

---

## Project structure

```
devops-deployment-demo/
├── README.md
├── app/                      # the application (shared by all 3 methods)
│   ├── app.py
│   ├── requirements.txt
│   └── templates/index.html
├── vm/                       # Method 1: bare VM
│   ├── setup.sh              # provisions the VM and installs a systemd service
│   └── myapp.service         # systemd unit
├── docker/                   # Method 2: Docker
│   ├── Dockerfile
│   ├── .dockerignore
│   └── docker-compose.yml
└── k8s/                      # Method 3: Kubernetes
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml          # optional
```

---

## The application

`app/app.py` is a Flask app exposing three routes:

| Route        | Purpose                                            |
|--------------|----------------------------------------------------|
| `/`          | HTML page showing hostname / mode / version / visits |
| `/api/info`  | Same data as JSON                                   |
| `/healthz`   | Health check used by Docker & Kubernetes probes    |

It reads `DEPLOY_MODE`, `APP_VERSION`, `GREETING`, and `PORT` from environment
variables. Each deployment method sets those differently — that's how the badge
on the page tells you which method you're looking at.

### Run it locally (no infra)

```bash
apt install python3.12-venv
cd app
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python app.py
# open http://localhost:8080
```

---

## Method 1 — Deploy directly on a VM

**Idea:** install the OS packages, a Python virtualenv, and run the app as a
long-lived background service managed by `systemd`. This is the "classic" way
apps were deployed for decades.

### Steps

1. Get a Linux VM (Ubuntu/Debian) — e.g. an EC2 instance, a DigitalOcean
   droplet, a local VirtualBox/Multipass VM. Make sure port `8080` is open.
2. Copy this project onto the VM (e.g. `scp -r devops-deployment-demo user@vm:~`).
3. Run the setup script:

   ```bash
   cd devops-deployment-demo/vm
   sudo bash setup.sh
   ```

   The script: installs `python3`/`venv`, creates a dedicated `myapp` user,
   copies the app to `/opt/myapp`, builds a virtualenv, installs the systemd
   unit, and starts the service.

4. Visit `http://<vm-ip>:8080`.

### Managing it

```bash
systemctl status myapp        # is it running?
systemctl restart myapp       # restart
journalctl -u myapp -f        # tail logs
```

### What you notice
- You had to prepare the machine yourself (packages, user, Python).
- The app shares the VM's OS and libraries with everything else on it.
- Scaling = get another VM and repeat, or run a second copy on another port and
  put a load balancer in front by hand.
- The hostname on the page is the VM's hostname and never changes.

---

## Method 2 — Containerize with Docker

**Idea:** package the app *and its dependencies* into an image. The image runs
identically on any machine with Docker — "works on my machine" becomes "works
everywhere."

### Prerequisites
Docker installed (`docker --version`).

### Steps

1. Build the image (run from the **project root**):

   ```bash
   docker build -t devops-demo:1.0.0 -f docker/Dockerfile .
   docker save devops-demo:1.0.0 -o devops-demo:1.0.0.tar
  sudo ctr -n=k8s.io images import devops-demo:1.0.0.tar 
   ```

2. Run a container:

   ```bash
   docker run -d --name demo -p 8080:8080 devops-demo:1.0.0
   ```

3. Visit `http://localhost:8080`. The hostname shown is the container id.

Or do both in one command with Compose:

```bash
cd docker
docker compose up --build
```

### Managing it

```bash
docker ps                 # running containers (+ health status)
docker logs -f demo       # logs
docker stop demo && docker rm demo
```

### What you notice
- No fiddling with the host OS — Python and libs are baked into the image.
- Start/stop is seconds, not minutes.
- The container is isolated from the host and other containers.
- Scaling is easy-ish: `docker run` more containers — but *you* still manage
  ports, restarts, and load balancing across them.

---

## Method 3 — Orchestrate with Kubernetes

**Idea:** hand Docker containers to an orchestrator that runs many copies,
restarts crashed ones, load-balances traffic, and rolls out updates — all
declaratively from YAML.

### Prerequisites
A cluster + `kubectl`. Easiest locally is **minikube** or **kind**.

```bash
minikube start
```

### Steps

1. Make the image available to the cluster. On a local cluster you *load* it
   rather than pushing to a registry:

   ```bash
   # build first (from project root)
   docker build -t devops-demo:1.0.0 -f docker/Dockerfile .

   # minikube:
   minikube image load devops-demo:1.0.0
   # kind:
   # kind load docker-image devops-demo:1.0.0
   ```

2. Apply the manifests:

   ```bash
   kubectl apply -f k8s/configmap.yaml
   kubectl apply -f k8s/deployment.yaml
   kubectl apply -f k8s/service.yaml
   ```

3. Watch the pods come up:

   ```bash
   kubectl get pods -w
   ```

4. Open the app:

   ```bash
   minikube service devops-demo --url
   # open the printed URL, then REFRESH a few times and watch the hostname change
   ```

### Try the superpowers

```bash
# Scale up/down live
kubectl scale deployment devops-demo --replicas=5

# Self-healing: delete a pod, k8s recreates it
kubectl delete pod <pod-name>
kubectl get pods

# Rolling update to a new version (rebuild+reload image as v1.1.0 first)
kubectl set image deployment/devops-demo web=devops-demo:1.1.0
kubectl rollout status deployment/devops-demo
kubectl rollout undo deployment/devops-demo   # instant rollback
```

### Cleanup

```bash
kubectl delete -f k8s/
minikube stop
```

### What you notice
- You declare the *desired state* ("I want 3 healthy replicas") and k8s makes it
  true and keeps it true.
- Load balancing, health-based traffic routing, restarts, and rolling updates
  are built in.
- Config lives in a ConfigMap, separate from the image.
- The hostname on the page changes as the Service spreads requests over pods.

---

## Side-by-side: how they differ

| Aspect | VM (Method 1) | Docker (Method 2) | Kubernetes (Method 3) |
|---|---|---|---|
| **What you ship** | Source + manual setup | A self-contained image | Images + declarative YAML |
| **Isolation** | Shares the host OS with everything | Process/filesystem isolation per container | Same as Docker, per pod |
| **Dependencies** | Installed on the host by hand | Baked into the image | Baked into the image |
| **"Works on my machine"** | Common problem | Solved | Solved |
| **Startup time** | Minutes (provision OS) | Seconds | Seconds (per pod) |
| **Scaling** | New VM, manual LB | `docker run` more, manual LB | `kubectl scale`, built-in LB |
| **Self-healing** | You (or a script) restart it | `--restart` policy per container | Automatic across the cluster |
| **Rolling updates / rollback** | Manual, risky | Manual | Built-in, one command |
| **Config management** | Files / env on the host | Env vars / mounts | ConfigMaps & Secrets |
| **Resource overhead** | Whole OS per VM | Just the app + libs | App + libs + control plane |
| **Best for** | Simple, single-service, few changes | Consistent packaging & local dev | Many services, scale, high availability |

### One-line mental model
- **VM** = *a whole computer* you set up and babysit.
- **Docker** = *the app in a box* that runs the same everywhere.
- **Kubernetes** = *a robot ops team* that runs, heals, scales, and updates your
  boxes for you.

### How they build on each other
These aren't rivals — they stack. Docker *packages* what the VM had to install
by hand. Kubernetes *runs and manages* the Docker containers at scale. A real
Kubernetes cluster is itself a bunch of VMs. So the progression VM → Docker →
Kubernetes is roughly: **run it → package it → orchestrate it.**

---

## Troubleshooting

- **Port 8080 already in use** → stop the other process, or change the published
  port (`-p 9090:8080`, or the Service `nodePort`).
- **k8s pods stuck in `ErrImagePull` / `ImagePullBackOff`** → you didn't load
  the image into the cluster; run the `minikube image load` / `kind load` step,
  and keep `imagePullPolicy: IfNotPresent`.
- **`CrashLoopBackOff`** → `kubectl logs <pod>` to see the app error.
- **VM setup fails on non-Debian distros** → `setup.sh` uses `apt-get`; adapt
  the package step for your distro (`dnf`, `yum`, etc.).
