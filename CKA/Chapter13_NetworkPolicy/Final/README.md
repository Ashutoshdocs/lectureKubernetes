# Kubernetes NetworkPolicy Demo — Ingress vs Egress

Two namespaces, one nginx pod in each. Each pod serves a page saying **`You hit <podname>`**, so every test shows exactly who answered.

```
 namespace: team-a               namespace: team-b
 ┌─────────────────┐             ┌─────────────────┐
 │  pod-a (nginx)  │ ◀─────────▶ │  pod-b (nginx)  │
 │  svc: web       │             │  svc: web       │
 └─────────────────┘             └─────────────────┘
```

## Files

| File | What it does |
|---|---|
| `00-setup.yaml` | Namespaces `team-a`/`team-b`, pods `pod-a`/`pod-b`, a `web` Service in each |
| `01-deny-all-ingress-team-b.yaml` | Deny all **incoming** traffic to every pod in team-b |
| `02-deny-all-egress-team-a.yaml` | Deny all **outgoing** traffic from every pod in team-a |
| `03-pod-b-allow-ingress-deny-egress.yaml` | pod-b: allow ingress (port 80 from team-a), deny all egress |
| `demo.sh` | Guided run of every step with tests and explanations |

## Prerequisite: a CNI that enforces NetworkPolicy

NetworkPolicy objects are only *enforced* by the network plugin. Without one that supports them, the policies apply silently and nothing gets blocked.

```bash
# minikube
minikube start --cni=calico

# or kind (disable default CNI, install Calico)
kind create cluster --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```
Cilium works equally well. Managed clusters: GKE (Dataplane V2), EKS (VPC CNI network policy enabled), AKS (Azure/Calico/Cilium policy).

## Run it

```bash
chmod +x demo.sh
./demo.sh            # pauses between steps — good for teaching
AUTO=1 ./demo.sh     # runs straight through
```

## Core concepts

- **Ingress** — traffic coming **into** the pod the policy selects.
- **Egress** — traffic going **out of** the pod the policy selects.
- **Default allow** — with no policy selecting a pod, all traffic is allowed.
- **Isolation by selection** — once any policy selects a pod for a direction (listed in `policyTypes`), that direction becomes deny-by-default and only rules you write open it up.
- **Additive** — multiple policies are OR'ed together. There is no "deny" rule; you deny by selecting a pod and not allowing.
- **Stateful** — replies to an allowed connection always get through. Egress-deny does not stop a pod from *answering*; it stops it from *starting* connections.
- **DNS is egress** — denying egress also blocks lookups to CoreDNS on port 53.

### Anatomy of a "deny all" policy
```yaml
spec:
  podSelector: {}        # {} = every pod in this namespace
  policyTypes:
    - Ingress            # and/or Egress
  # no ingress:/egress: rules → nothing allowed
```

## Expected results

| Step | Policy in place | a → b | b → a | Lesson |
|---|---|---|---|---|
| 1 | none | ✔ | ✔ | Default allow |
| 2 | deny ingress (team-b) | ✘ timeout | ✔ | Ingress only guards the receiver; replies are allowed |
| 3 | deny egress (team-a) | ✘ DNS fails | ✔ | Egress blocks DNS too; replies still leave |
| 4 | pod-b: ingress allow, egress deny | ✔ | ✘ DNS fails | Same pod can accept connections but not start them |

## Manual commands (without the script)

```bash
kubectl apply -f 00-setup.yaml

# test a → b and b → a
kubectl exec -n team-a pod-a -- curl -s --max-time 3 http://web.team-b.svc.cluster.local
kubectl exec -n team-b pod-b -- curl -s --max-time 3 http://web.team-a.svc.cluster.local

kubectl apply  -f 01-deny-all-ingress-team-b.yaml   # re-test
kubectl delete -f 01-deny-all-ingress-team-b.yaml

kubectl apply  -f 02-deny-all-egress-team-a.yaml    # re-test
kubectl delete -f 02-deny-all-egress-team-a.yaml

kubectl apply  -f 03-pod-b-allow-ingress-deny-egress.yaml   # re-test
```

## Follow-up exercise: allow DNS with deny-egress

Add this to team-a after scenario 2 — pod-a can then resolve names, but connections still fail:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```

## Cleanup
```bash
kubectl delete ns team-a team-b
```
