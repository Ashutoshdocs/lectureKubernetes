# Kubernetes `emptyDir` Demo: Disk vs RAM (tmpfs)

A hands-on lab that teaches what `emptyDir` is, how the **disk-backed** and **RAM-backed** (`medium: Memory`) flavours differ, **proves RAM is faster** with a benchmark, and shows the trap that bites people in production.

---

## 1. What is `emptyDir`?

An `emptyDir` is a scratch volume that:

- is **created empty** when the Pod is scheduled onto a node,
- is **shared by all containers** in that Pod,
- **survives container restarts** (crash → restart keeps the data),
- is **deleted forever** when the Pod is removed from the node.

```
Pod lifetime  ───────────────────────────────────────────►
emptyDir      [created]════════ data lives here ═════════[deleted]
container A        ▲ crash/restart ▲   (data still there)
```

## 2. The two flavours

| | Disk-backed (default) | RAM-backed (`medium: Memory`) |
|---|---|---|
| YAML | `emptyDir: {}` | `emptyDir: { medium: Memory }` |
| Lives in | Node disk: `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/` | `tmpfs` (kernel RAM filesystem) |
| Speed | Limited by node disk (SSD / network disk) | Memory speed, no real fsync cost |
| Counted against | Node **ephemeral-storage** | Container **memory** limit |
| Over-filling | Pod **evicted** (sizeLimit / disk pressure) | Container **OOMKilled** or pod evicted |
| Survives node reboot? | No (pod is gone anyway) | No |
| Data ever touches disk? | Yes | No (unless the node swaps) |
| Typical size | GBs | MBs to a few hundred MB |

> Key mental model: **RAM-backed emptyDir is not "free fast storage". Every byte you write is a byte of your container's memory budget.**

---

## 3. Files in this demo

| File | Purpose |
|---|---|
| `01-emptydir-disk.yaml` | Pod with a disk-backed emptyDir at `/scratch` |
| `02-emptydir-memory.yaml` | Pod with a RAM-backed (tmpfs) emptyDir at `/scratch` |
| `03-sharing-demo.yaml` | Two containers sharing one emptyDir (basics lesson) |
| `04-memory-limit-danger.yaml` | Proves tmpfs counts toward memory limit → OOMKilled |
| `benchmark.sh` | Write / read / small-file fsync benchmark (runs inside the pod) |
| `run-demo.sh` | Deploys both pods, benchmarks both, prints a comparison table |
| `cleanup.sh` | Deletes every demo pod |

Prerequisites: any cluster (kind, minikube, k3s, EKS, GKE, AKS) and `kubectl`. Images used: `alpine:3.20`.

```bash
chmod +x *.sh
```

---

## 4. Lab 1 – Sharing basics

```bash
kubectl apply -f 03-sharing-demo.yaml
kubectl logs -f emptydir-sharing -c reader        # reader sees writer's lines
```

Prove it survives a **container** restart but not a **pod** delete:

```bash
kubectl exec emptydir-sharing -c writer -- kill 1   # restart the writer container
kubectl exec emptydir-sharing -c reader -- wc -l /shared/log.txt   # count keeps growing

kubectl delete pod emptydir-sharing && kubectl apply -f 03-sharing-demo.yaml
kubectl exec emptydir-sharing -c reader -- wc -l /shared/log.txt   # back to ~0
```

---

## 5. Lab 2 – See the difference with your own eyes

```bash
kubectl apply -f 01-emptydir-disk.yaml -f 02-emptydir-memory.yaml
kubectl wait --for=condition=Ready pod -l demo=emptydir --timeout=120s

kubectl exec emptydir-disk   -- sh -c 'mount | grep /scratch; df -h /scratch'
kubectl exec emptydir-memory -- sh -c 'mount | grep /scratch; df -h /scratch'
```

Expected:

```
# disk
/dev/nvme0n1p1 on /scratch type ext4 (rw,...)       <- real disk
# memory
tmpfs on /scratch type tmpfs (rw,...,size=524288k)  <- RAM, size = sizeLimit
```

Now watch memory usage jump when you write to tmpfs:

```bash
kubectl exec emptydir-memory -- cat /sys/fs/cgroup/memory.current        # before
kubectl exec emptydir-memory -- dd if=/dev/zero of=/scratch/x bs=1M count=200
kubectl exec emptydir-memory -- cat /sys/fs/cgroup/memory.current        # ~200MB higher!
kubectl exec emptydir-memory -- rm /scratch/x
```

Do the same on `emptydir-disk` and memory barely moves (apart from reclaimable page cache).

---

## 6. Lab 3 – Prove RAM is faster

```bash
./run-demo.sh
```

The benchmark runs three tests in both pods:

1. **Sequential write + fsync** – writes 256 MB and forces it to storage.
2. **Sequential read** – reads it back.
3. **1000 small 4 KB files, each fsync'd** – mimics databases, build caches, lock files, session stores.

Tune it: `SIZE_MB=512 SMALL_FILES=3000 ./run-demo.sh`

### Sample result (real run, fast local NVMe VM, 128 MB / 500 files)

```
Test                         Disk(ms)   RAM(ms)  RAM faster
Sequential write + fsync          176        53        3.3x
Sequential read                    25        29        0.9x
Small files + fsync               738       504        1.5x
```

On cloud nodes whose root disk is **network-attached** (EBS gp3, GCP pd-balanced, Azure managed disk) the gaps are usually far bigger, often **10x–100x** on fsync-heavy work, because each fsync is a network round trip.

### How to read the results honestly

- **Writes with fsync** – RAM wins big. tmpfs has nothing to flush, so fsync returns instantly.
- **Sequential reads** – often a tie. Linux caches recently read/written disk files in RAM (the page cache), so a disk read of hot data *is already* a RAM read. RAM-backed emptyDir mainly wins on **writes, fsync, metadata ops, and cold data**.
- **Small files** – RAM wins; every create + fsync on disk costs real I/O latency.

---

## 7. Lab 4 – The trap: RAM emptyDir eats your memory limit

```bash
kubectl apply -f 04-memory-limit-danger.yaml
kubectl get pod emptydir-oom -w
kubectl describe pod emptydir-oom | grep -A3 -i "last state\|reason"
```

The container has a 200 Mi memory limit and writes 300 MB to tmpfs → **OOMKilled** (or **Evicted** depending on version/config). Your app code didn't allocate a single byte of heap, yet it died of out-of-memory.

Rules that follow:

1. **Always set `sizeLimit`** on Memory-backed emptyDir.
2. **memory limit ≥ app's normal usage + sizeLimit.**
3. Recent Kubernetes versions size the tmpfs to the smaller of `sizeLimit` and the pod's memory limit; older versions defaulted to **half the node's RAM**. Don't rely on defaults, set it explicitly.
4. Files left in tmpfs are never reclaimed until deleted. Clean up after yourself.

---

## 8. When to use which

### Use RAM-backed (`medium: Memory`) when

- **Speed matters and data is small**: hot caches, temporary sort/merge buffers, compiled templates.
- **Lots of tiny writes / fsyncs**: test databases in CI (Postgres/MySQL data dir for throwaway test runs), build caches, lock/pid files.
- **Secrets or sensitive temp data must never touch disk**: decrypted keys, tokens rendered by an init container, temp files of PDF/image processing with personal data.
- **Shared memory for apps**: mount at `/dev/shm` for Chrome/Puppeteer/Selenium, PyTorch DataLoader workers, Oracle, Postgres (the default 64 MB `/dev/shm` crashes these):
  ```yaml
  volumeMounts:
    - name: dshm
      mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 1Gi
  ```

### Use disk-backed (default) when

- Data is **large** (hundreds of MB to GBs): video transcoding, ML dataset downloads, unpacking archives, log buffering.
- Memory is **expensive or tight** on your nodes.
- You want **eviction rather than OOM** when it overflows.
- Speed is "good enough", which is most of the time thanks to the page cache.

### Use neither (use a PersistentVolume) when

- Data must **survive pod deletion, rescheduling, or node failure** (real databases, user uploads, state). `emptyDir` of either flavour is always throwaway.

### Quick decision flow

```
Must data survive pod deletion? ── yes ──► PersistentVolumeClaim
        │ no
        ▼
Is it bigger than ~500 MB? ─────── yes ──► emptyDir (disk)
        │ no
        ▼
Sensitive, fsync-heavy, /dev/shm,
or latency-critical? ───────────── yes ──► emptyDir (medium: Memory) + sizeLimit
        │ no
        ▼
                                         emptyDir (disk)  ← safe default
```

---

## 9. Cleanup

```bash
./cleanup.sh
```

## 10. Cheat sheet

```yaml
# Disk
volumes:
  - name: scratch
    emptyDir:
      sizeLimit: 2Gi

# RAM
volumes:
  - name: scratch
    emptyDir:
      medium: Memory
      sizeLimit: 256Mi   # and raise the container memory limit by this much
```
