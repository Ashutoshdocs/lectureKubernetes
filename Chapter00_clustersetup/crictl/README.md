# Installing and Configuring `crictl`

This guide installs `crictl` **v1.31.1** and points it at a local **containerd** socket.

## What is `crictl`?

`crictl` is a command-line client for **CRI** (the *Container Runtime Interface*), the gRPC API that Kubernetes' kubelet uses to talk to a container runtime such as containerd or CRI-O. It ships as part of the [`cri-tools`](https://github.com/kubernetes-sigs/cri-tools) project maintained by kubernetes-sigs.

It looks a lot like Docker's CLI, but it operates **directly against the runtime**, below Kubernetes. That makes it the standard tool for **debugging a node** when you can't (or don't want to) go through `kubectl` — for example when the API server is unreachable, a pod is stuck, or you need to see what the runtime is actually doing.

`crictl` speaks in CRI concepts, so its objects are:

- **pods** (pod sandboxes) — `crictl pods`
- **containers** — `crictl ps`
- **images** — `crictl images`

A key thing to keep in mind: `crictl` only sees what the runtime knows about. Containers created by `docker run` outside of the CRI won't show up, and changes you make with `crictl` are made behind the kubelet's back — so on a live Kubernetes node, prefer `kubectl` for anything the kubelet manages, and reach for `crictl` for inspection and break-glass debugging.

## Prerequisites

- Linux, `amd64` architecture (the download URL below is arch-specific)
- `wget` and `tar`
- Root / `sudo` access (installs into `/usr/local/bin` and writes `/etc/crictl.yaml`)
- A running container runtime exposing a CRI socket — this guide assumes **containerd** at `/run/containerd/containerd.sock`

## Installation

```bash
cd /tmp

VERSION="v1.31.1"

# Download the release tarball from the cri-tools GitHub releases
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/${VERSION}/crictl-${VERSION}-linux-amd64.tar.gz

# Extract it (produces a single `crictl` binary)
tar -xzf crictl-${VERSION}-linux-amd64.tar.gz

# Install to a directory on your PATH and make it executable
mv crictl /usr/local/bin/
chmod +x /usr/local/bin/crictl

# Verify
crictl --version
```

`crictl --version` should print `crictl version v1.31.1`.

> **Tip:** Match the `crictl` minor version to your Kubernetes/kubelet minor version where you can (here, `v1.31.x`). The tools follow Kubernetes' release cadence and are tested against the matching version.

## Configuration

`crictl` needs to know which runtime socket to talk to. The config file lives at `/etc/crictl.yaml`:

```bash
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

### Config fields

| Field | Meaning |
| --- | --- |
| `runtime-endpoint` | Socket for runtime operations (pods, containers, exec, logs). |
| `image-endpoint` | Socket for image operations (pull, list, remove). Usually the same socket as the runtime. |
| `timeout` | Timeout in seconds for connecting to the endpoint. |
| `debug` | When `true`, prints verbose request/response output — useful for troubleshooting. |

If you're using **CRI-O** instead of containerd, point the endpoints at `unix:///var/run/crio/crio.sock`.

You can override the config at runtime with flags (e.g. `crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps`) or the `CONTAINER_RUNTIME_ENDPOINT` environment variable.

## Verify it works

```bash
crictl info
```

`crictl info` returns the runtime's status and configuration as JSON. If it prints runtime details without a connection error, `crictl` is talking to your runtime correctly.

If it errors, the usual causes are: the runtime isn't running, the socket path in `/etc/crictl.yaml` is wrong, or you don't have permission to read the socket (try `sudo`).

## Common commands

```bash
crictl pods                 # list pod sandboxes
crictl ps                   # list running containers
crictl ps -a                # list all containers, including stopped
crictl images               # list images
crictl pull nginx:latest    # pull an image
crictl logs <container-id>   # view a container's logs
crictl exec -it <container-id> sh   # get a shell in a container
crictl inspect <container-id>       # detailed JSON for a container
crictl stats                # live resource usage
crictl rmi --prune          # remove unused images
```

Add `-o table`, `-o json`, or `-o yaml` to many commands to control output formatting.

## Cleanup

The downloaded tarball in `/tmp` is no longer needed after install:

```bash
rm -f /tmp/crictl-${VERSION}-linux-amd64.tar.gz
```

## References

- cri-tools project: <https://github.com/kubernetes-sigs/cri-tools>
- `crictl` user guide: <https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md>
