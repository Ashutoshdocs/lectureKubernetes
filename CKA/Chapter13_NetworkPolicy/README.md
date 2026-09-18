# Kubernetes NetworkPolicy — Hands-On Demo

A small, self-contained lab that teaches how Kubernetes `NetworkPolicy` controls
pod-to-pod traffic. You'll deploy three pods, apply policies with different
rules for each, and prove — with `curl` — exactly which connections are allowed
and which are dropped.

By the end you'll understand: default-allow vs default-deny, ingress vs egress,
why *both* pods in a connection must agree, why blocked traffic *hangs instead
of refusing*, the empty-list vs empty-rule trap, and the DNS gotcha.

---

## The scenario

| Pod   | May SEND to        | May RECEIVE from    |
|-------|--------------------|---------------------|
| pod-a | pod-c only         | no one              |
| pod-b | anyone             | anyone              |
| pod-c | no one             | pod-a and pod-b only|

Which produces this connectivity matrix (rows = who initiates the `curl`):

| FROM \ TO | pod-a   | pod-b   | pod-c   |
|-----------|---------|---------|---------|
| **pod-a** |   —     | BLOCKED | ALLOWED |
| **pod-b** | BLOCKED |   —     | ALLOWED |
| **pod-c** | BLOCKED | BLOCKED |   —     |

Take a moment to see *why* each cell is what it is — the reasoning is in
[Reading the matrix](#reading-the-matrix) below.

---

## Prerequisites (read this — it's the #1 reason demos "fail")

**Your cluster's CNI must enforce NetworkPolicy.** A plain kubeadm install with
**flannel does not** — it silently ignores every policy, so *all* traffic is
allowed and the demo looks broken when it's actually the opposite. Use one of:
Calico, Cilium, Weave Net, or Antrea.

Quick check — this pod should be present if you have a policy-capable CNI:

```bash
kubectl get pods -A | grep -Ei 'calico|cilium|weave|antrea'
```

Also needed:
- A working `kubectl` against a cluster you can schedule pods on.
- Outbound internet access at pod-startup time (the pods `apt install curl` when
  they boot — see [Why curl is installed at startup](#why-curl-is-installed-at-startup)).

Single-node cluster? Remove the control-plane taint so pods can schedule:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

---

## Files

| File                       | Purpose                                             |
|----------------------------|-----------------------------------------------------|
| `pods.yaml`                | The three nginx pods (also have `curl` for testing) |
| `network-policies.yaml`    | default-deny + one policy per pod                    |
| `optional-allow-dns.yaml`  | Re-opens port 53 so you can curl by name (optional)  |
| `test-connectivity.sh`     | Runs the whole matrix and checks it for you          |

---

## Run it

### 1. Namespace and pods

```bash
kubectl create namespace netpol-demo
kubectl apply -f pods.yaml
kubectl get pods -n netpol-demo -o wide
```

Wait until all three are `Running`. **Do this before applying any policy** — the
pods need open egress at boot to fetch `curl`.

### 2. Confirm everything can talk (baseline)

With no policies yet, Kubernetes default is *allow all*. Grab the IPs and prove it:

```bash
kubectl get pods -n netpol-demo -o wide      # note the IP column
kubectl exec -n netpol-demo pod-a -- curl -s -o /dev/null -w '%{http_code}\n' http://<pod-b-ip>
# -> 200
```

### 3. Apply the policies

```bash
kubectl apply -f network-policies.yaml
kubectl get networkpolicy -n netpol-demo
```

### 4. Test

Automated (recommended):

```bash
chmod +x test-connectivity.sh
./test-connectivity.sh
```

Or by hand — exec into a pod and curl a target IP:

```bash
kubectl exec -it -n netpol-demo pod-a -- bash
# inside the pod:
curl --connect-timeout 5 http://<pod-c-ip>   # ALLOWED  -> HTML comes back
curl --connect-timeout 5 http://<pod-b-ip>   # BLOCKED  -> hangs, then times out
exit
```

> **BLOCKED = timeout, not "connection refused".** NetworkPolicy silently drops
> packets, so the sender just waits. Always use `--connect-timeout` so you're not
> stuck. A *refused* connection would mean nothing is listening — a different
> problem entirely.

---

## Reading the matrix

The one rule that explains every cell:

> A connection is allowed only if **the sender's egress permits the destination
> AND the destination's ingress permits the sender.** If either side says no,
> the packet is dropped.

Walking through the interesting cases:

- **pod-a → pod-c = ALLOWED.** pod-a's egress lists pod-c, and pod-c's ingress
  lists pod-a. Both sides agree.
- **pod-a → pod-b = BLOCKED.** pod-a's egress *only* allows pod-c, so the packet
  never even leaves pod-a — even though pod-b would happily accept it.
- **pod-b → pod-a = BLOCKED.** pod-b's egress is wide open, but pod-a denies
  *all* ingress. "Send to anyone" only means pod-b's own side is open; delivery
  still depends on the target.
- **pod-b → pod-c = ALLOWED.** pod-b's egress is open, and pod-c's ingress lists pod-b.
- **pod-c → anything = BLOCKED.** pod-c has `egress: []` (deny all outbound), so
  it can't initiate anything.

**Stateful bonus:** pod-c has no egress, yet `pod-a → pod-c` still returns HTML.
NetworkPolicy is connection-tracked — reply packets on an *already-allowed*
connection are permitted automatically. Egress rules only govern connections a
pod *starts* itself.

---

## Concepts this demo teaches

**Default is allow-all.** With zero policies, every pod can reach every pod.
NetworkPolicy is opt-in.

**Selecting a pod flips its default to deny — for that direction only.** The
moment *any* policy names a pod under `policyTypes: [Ingress]`, all its inbound
traffic is denied except what some rule explicitly allows. Egress works the
same, independently.

**Policies are additive (a union).** Multiple policies on the same pod can only
ever *add* allowances. There is no "deny" rule that overrides an allow — you
achieve deny by simply not allowing.

**Empty list vs empty rule — the classic trap:**

| YAML                | Meaning              |
|---------------------|----------------------|
| `ingress: []`       | no rules → **deny all** inbound |
| `ingress:` `- {}`   | one match-everything rule → **allow all** inbound |
| (omit `ingress:` entirely, but keep `Ingress` in `policyTypes`) | **deny all** inbound |

**Peers: OR within a list, AND within one item.** Two `- podSelector` entries in
the same `from:` list mean "this OR that" (that's how pod-c allows a *or* b). But
a `namespaceSelector` and a `podSelector` inside the *same* list item mean
"pods matching that label *in* namespaces matching that label" (AND).

**L3/L4 only.** NetworkPolicy filters by IP, protocol, and port — not URLs,
methods, or headers. That's the job of a service mesh / L7 policy.

---

## The DNS gotcha

`default-deny` also blocks egress to CoreDNS (port 53). The IP-based curls above
don't care, but the instant you try a **name** it hangs:

```bash
kubectl exec -n netpol-demo pod-a -- curl --connect-timeout 5 http://pod-b   # hangs on DNS
```

Fix it by re-opening only port 53:

```bash
kubectl apply -f optional-allow-dns.yaml
```

This grants DNS to pod-a and pod-b (the initiators). pod-c is left with zero
egress on purpose, keeping it true to "may send to no one."

---

## Why curl is installed at startup

The `nginx` image has no `curl`. The pods run
`apt-get install -y curl` in their startup command, *before* any policy exists,
while egress is still open. If you tried to install it *after* applying
`default-deny`, apt would hang — because the deny policy blocks the internet.
That ordering constraint (`pods.yaml` first, always) is itself the lesson.

Consequence: if you `kubectl delete` and recreate a pod *while policies are
active*, it can't fetch curl and may crash-loop. Either delete the policies
first, or `kubectl apply -f pods.yaml` before re-applying policies.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Everything is ALLOWED even after policies | CNI doesn't enforce NetworkPolicy (flannel). Switch to Calico/Cilium/Weave/Antrea. |
| Pod stuck `Pending` | `nodeName` points at a node that doesn't exist. Comment it out or fix the name (`kubectl get nodes`). |
| Pod `CrashLoopBackOff` after recreate | Recreated under active deny policy → couldn't install curl. Delete policies, re-apply pods, re-apply policies. |
| `curl` hangs on a hostname | DNS blocked → apply `optional-allow-dns.yaml`. |
| `curl: command not found` | Pod started with no internet egress; apt couldn't fetch curl at boot. |

Handy inspection commands:

```bash
kubectl describe networkpolicy pod-c-policy -n netpol-demo
kubectl get networkpolicy -n netpol-demo -o yaml
```

---

## Exercises

1. Make **pod-a reachable from pod-b** — change one policy, predict the new
   matrix, then verify.
2. Restrict pod-c's ingress to **port 80 only**, and confirm another port is
   dropped.
3. Add a **pod-d** with a new label and allow it to reach pod-c using a
   `matchExpressions` selector.
4. Allow pod-b to reach the **internet** (e.g. `curl https://example.com`) while
   keeping everything else locked down. (Hint: it needs both DNS *and* egress to
   external IPs.)

---

## Cleanup

```bash
kubectl delete namespace netpol-demo
```

That removes the pods and every policy in one shot.
