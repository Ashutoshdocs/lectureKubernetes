# Kubernetes Deprecated & Removed API Demo

A hands-on walkthrough for detecting, migrating, and verifying Kubernetes APIs that have been **deprecated** or **removed** across versions. It uses a deliberately outdated `Ingress` manifest (`networking.k8s.io/v1beta1`) to demonstrate the full lifecycle: catch it, convert it, and prove the difference between a cluster that still tolerates the old API and one that has removed it entirely.

## What This Demonstrates

- **Deprecated API** (`v1.21`): the old `networking.k8s.io/v1beta1` Ingress still applies, but the API server emits a deprecation warning.
- **Removed API** (`v1.25`): the same manifest is flat-out rejected — the API version no longer exists.
- **Detection & migration** using Pluto, `kubectl-convert`, and the API server's own deprecation metrics.

## Tools Installed

| Tool | Purpose |
|------|---------|
| **Docker** | Container runtime required by kind |
| **kubectl** | Kubernetes CLI |
| **kind** | Runs local Kubernetes clusters inside Docker |
| **kubectl-convert** | Plugin that rewrites manifests to newer API versions |
| **pluto** | Fairwinds tool that detects deprecated/removed APIs in files and live clusters |

## Prerequisites

- A Linux (amd64) host with `curl` and `sudo` access
- Internet access to the domains hosting the release binaries
- After adding yourself to the `docker` group you may need a new shell (the script uses `newgrp docker`)

> **Note on kubectl versions:** the script installs the latest stable `kubectl`, then pins `v1.21.14` over it. Feel free to keep a single version — a recent `kubectl` works fine against both clusters here.

## Installation

Run the setup commands to install Docker, kubectl, kind, kubectl-convert, and pluto:

```bash
# Docker (kind needs a container runtime)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# kubectl (latest stable)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# kind
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
sudo install kind /usr/local/bin/

# kubectl-convert
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
sudo install kubectl-convert /usr/local/bin/

# pluto (Fairwinds)
PLUTO_VER=$(curl -s https://api.github.com/repos/FairwindsOps/pluto/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+' | tr -d v)
curl -L "https://github.com/FairwindsOps/pluto/releases/download/v${PLUTO_VER}/pluto_${PLUTO_VER}_linux_amd64.tar.gz" | tar xz pluto
sudo install pluto /usr/local/bin/
pluto version
```

## Walkthrough

### 1. Create a cluster on an older Kubernetes (v1.21)

```bash
kind create cluster --name deprec-demo --image kindest/node:v1.21.14
kubectl config use-context kind-deprec-demo
kubectl version --short
```

### 2. Apply a deprecated manifest

`old-ingress.yaml` uses `networking.k8s.io/v1beta1`, which is deprecated in v1.21:

```yaml
apiVersion: networking.k8s.io/v1beta1   # <-- deprecated
kind: Ingress
metadata:
  name: demo-ingress
spec:
  rules:
  - host: demo.example.com
    http:
      paths:
      - path: /
        backend:
          serviceName: demo-svc
          servicePort: 80
```

```bash
kubectl apply -f old-ingress.yaml
```

This succeeds on v1.21 but prints a deprecation warning.

### 3. Detect the deprecated APIs

```bash
# Scan manifest files on disk
pluto detect-files -d .

# Scan what's actually live in the cluster
pluto detect-all-in-cluster -owide

# Ask the API server itself which deprecated APIs are being hit
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

### 4. Convert the manifest to the current API

```bash
kubectl-convert -f old-ingress.yaml --output-version networking.k8s.io/v1 -o yaml > new-ingress.yaml
cat new-ingress.yaml
kubectl apply -f new-ingress.yaml   # no deprecation warning this time
```

The converter updates the `apiVersion` and reshapes the `backend` block to the newer `service.name` / `service.port` structure required by `networking.k8s.io/v1`.

### 5. Prove the API is *removed* in a newer cluster (v1.25)

```bash
kind create cluster --name removed-demo --image kindest/node:v1.25.3
kubectl config use-context kind-removed-demo

kubectl apply -f old-ingress.yaml
# error: unable to recognize "old-ingress.yaml": no matches for kind
#        "Ingress" in version "networking.k8s.io/v1beta1"

kubectl apply -f new-ingress.yaml   # works fine
```

This is the key lesson: **deprecated ≠ removed.** The old manifest that merely warned on v1.21 is rejected outright on v1.25.

### 6. Clean up

```bash
kind delete cluster --name deprec-demo
kind delete cluster --name removed-demo
```

## Ingress API: v1beta1 → v1 Changes

| `networking.k8s.io/v1beta1` | `networking.k8s.io/v1` |
|-----------------------------|------------------------|
| `backend.serviceName` | `backend.service.name` |
| `backend.servicePort` | `backend.service.port.number` |
| `path` optional | `pathType` required |

`networking.k8s.io/v1beta1` Ingress was deprecated in **v1.19** and removed in **v1.22**. (The demo uses v1.25 to show the removed behavior clearly.)

## Takeaways

- Run `pluto detect-files` in CI to catch deprecated APIs **before** they reach a cluster.
- Watch the `apiserver_requested_deprecated_apis` metric to find deprecated APIs still in active use.
- Use `kubectl-convert` to migrate manifests, but always review the output — structural changes (like the Ingress backend) aren't just a version bump.
- Test upgrades against the target Kubernetes version early; a removed API turns a warning into a hard failure.

## References

- Pluto — https://github.com/FairwindsOps/pluto
- kind — https://kind.sigs.k8s.io/
- Kubernetes Deprecated API Migration Guide — https://kubernetes.io/docs/reference/using-api/deprecation-guide/
