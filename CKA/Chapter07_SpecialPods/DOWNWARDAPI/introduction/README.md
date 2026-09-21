# Kubernetes Downward API — Hands-On Demo

A tiny demo that shows how a container can learn **facts about its own pod** — name,
namespace, node, and IP — **without calling the Kubernetes API**. Kubernetes injects these
values straight into the container as environment variables. That mechanism is the
**Downward API**.

```
Kubernetes knows:  pod name, namespace, node, IP, labels, resource limits, ...
      │  (the Downward API)
      ▼
Injects them into the container as env vars (or files)
      ▼
Your app just reads $MY_POD_NAME — no API call, no credentials needed
```

---

## What this demo teaches

### The problem it solves
An app often needs to know things about *itself*: "Which pod am I? Which node am I on? What's
my IP?" — for logging, metrics, tracing, or leader election. You *could* query the Kubernetes
API from inside the container, but that needs credentials and permissions. The **Downward
API** hands that metadata to the container directly, so the app just reads an env var.

### How it works in this file
Each `env` entry uses **`valueFrom.fieldRef`** to pull a field from the pod's own spec/status
into an environment variable:

| Env var        | `fieldPath`          | What it gives you            |
|----------------|----------------------|------------------------------|
| `MY_POD_NAME`  | `metadata.name`      | The pod's name               |
| `MY_NAMESPACE` | `metadata.namespace` | The namespace it runs in     |
| `MY_NODE`      | `spec.nodeName`      | The node it's scheduled on   |
| `MY_POD_IP`    | `status.podIP`       | The pod's cluster IP         |

The container just loops and echoes those variables every 10 seconds — proof that the values
are present inside the container.

> **Two ways to expose Downward API data:** as **env vars** (this demo, via `fieldRef`) or as
> **files** in a mounted volume (via a `downwardAPI` volume). Env vars are simplest; the file
> form is used for values that can change, like labels/annotations.

### What you can expose
- Via `fieldRef`: `metadata.name`, `metadata.namespace`, `metadata.uid`, `spec.nodeName`,
  `spec.serviceAccountName`, `status.podIP`, `status.hostIP`.
- Via `resourceFieldRef`: a container's CPU/memory **requests and limits**.
- Via a `downwardAPI` **volume**: also `metadata.labels` and `metadata.annotations` (these
  aren't allowed as env vars because they can change at runtime).

---

## File in this repo

| File               | What it is                                                            |
|--------------------|----------------------------------------------------------------------|
| `downwardapi.yml`  | A single busybox pod that injects pod name, namespace, node, and IP as env vars and prints them in a loop. |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.

---

## Steps

### 1. Apply the pod
```bash
kubectl apply -f downwardapi.yml
```

### 2. Wait for it to be running
```bash
kubectl get pod downwardapi-demo -w
```
Expected:
```
NAME               READY   STATUS    RESTARTS   AGE
downwardapi-demo   1/1     Running   0          ...
```
(Press `Ctrl+C` to stop watching.)

### 3. Watch the injected values (the whole point)
```bash
kubectl logs -f downwardapi-demo
```
Expected — the pod's own metadata, printed from inside the container:
```
Pod Name: downwardapi-demo
Namespace: default
Node Name: <your-node-name>
Pod IP: 10.244.1.7
----------------------
```
(`Ctrl+C` to stop following.)

### 4. Cross-check against what Kubernetes reports
Confirm the values the container printed match the cluster's own view:
```bash
kubectl get pod downwardapi-demo -o wide
```
The `NODE` and `IP` columns should match `MY_NODE` and `MY_POD_IP` from the logs. ✅

### 5. See the env vars live inside the container
```bash
kubectl exec downwardapi-demo -- env | grep MY_
```
Expected:
```
MY_POD_NAME=downwardapi-demo
MY_NAMESPACE=default
MY_NODE=<node>
MY_POD_IP=10.244.1.7
```

---

## Try it yourself — add another field

Add the host (node) IP by appending another `env` entry to the container, then re-apply:
```yaml
    - name: MY_HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
```
```bash
kubectl delete -f downwardapi.yml
kubectl apply -f downwardapi.yml
kubectl exec downwardapi-demo -- env | grep MY_
```
You'll now see `MY_HOST_IP` too — that's how you extend the Downward API to any supported
field.

---

## Key takeaways

- The **Downward API** injects a pod's own metadata into its containers — **no API call and
  no credentials** required.
- Use **`env.valueFrom.fieldRef`** for scalar fields (name, namespace, node, IP) and
  **`resourceFieldRef`** for CPU/memory requests & limits.
- Use a **`downwardAPI` volume** for values that can change at runtime, like **labels** and
  **annotations**.
- Common real uses: stamping logs/metrics with the pod name, telling a tracing system which
  node/IP served a request, and configuring apps that need to know their own identity.

---

## Cleanup

```bash
kubectl delete -f downwardapi.yml
```
