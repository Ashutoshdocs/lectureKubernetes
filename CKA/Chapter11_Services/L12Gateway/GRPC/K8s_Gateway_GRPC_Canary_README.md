# Kubernetes Gateway API + gRPC Routing + Stable/Canary Demo

> **Teaching Lab:** Kubernetes Gateway API with Envoy Gateway,
> `GRPCRoute`, gRPC service/method matching, and weighted Stable/Canary
> traffic splitting.
>
> **Recommended controller:** Envoy Gateway\
> **Gateway API resource:** `GRPCRoute`\
> **Example gRPC server:** Project Contour YAGES
> (`ghcr.io/projectcontour/yages:v0.1.0`)\
> **Audience:** Kubernetes administrators, DevOps/SRE engineers,
> trainers and CKAD/CKA learners.

------------------------------------------------------------------------

## 1. What You Will Learn

By the end of this practical, students will be able to:

1.  Explain the difference between **Ingress** and **Gateway API**.
2.  Understand `GatewayClass`, `Gateway`, `GRPCRoute`, `Service`, and
    `Deployment`.
3.  Install **Envoy Gateway**.
4.  Create a Gateway that accepts plaintext HTTP/2/gRPC traffic.
5.  Route a gRPC request using **service + method matching**.
6.  Split gRPC traffic between:
    -   **Stable = 90%**
    -   **Canary = 10%**
7.  Change the canary percentage:
    -   90/10
    -   80/20
    -   50/50
    -   0/100
8.  Verify Gateway and GRPCRoute status.
9.  Test gRPC using `grpcurl`.
10. Troubleshoot common Gateway API and gRPC failures.
11. Explain how this becomes a real production canary deployment
    pattern.

------------------------------------------------------------------------

# 2. Architecture

``` text
                         gRPC Client
                             |
                             | HTTP/2
                             | grpcurl
                             v
                 +-------------------------+
                 |   Gateway API Gateway   |
                 |       grpc-gateway      |
                 +------------+------------+
                              |
                              | GRPCRoute
                              | Echo/Ping
                              |
                     +--------+--------+
                     | Weighted Split  |
                     |                |
              90%    |                |    10%
                     v                v
              +-------------+  +-------------+
              | Stable SVC  |  | Canary SVC  |
              | grpc-stable |  | grpc-canary |
              +------+------+  +------+------+
                     |                |
                     v                v
              +-------------+  +-------------+
              | Stable Pods |  | Canary Pods |
              | version=1   |  | version=2   |
              +-------------+  +-------------+
```

### Important idea

The Kubernetes `Service` does **not** perform the 90/10 split in this
lab.

The split is declared in the **Gateway API `GRPCRoute`**:

``` yaml
backendRefs:
  - name: grpc-stable
    port: 9000
    weight: 90

  - name: grpc-canary
    port: 9000
    weight: 10
```

The weights are proportional. `90/10` means approximately 90% and 10%;
the weights do not have to add up to 100.

------------------------------------------------------------------------

# 3. Gateway API Objects

``` text
GatewayClass
     |
     | selects the controller
     v
Gateway
     |
     | accepts network traffic
     v
GRPCRoute
     |
     | understands gRPC service/method
     v
Service
     |
     v
Pods
```

## GatewayClass

Defines **which Gateway controller** manages the Gateway.

For Envoy Gateway:

``` yaml
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

## Gateway

Represents the traffic entry point.

Example:

``` yaml
kind: Gateway
```

## GRPCRoute

Defines gRPC routing.

Example:

``` yaml
kind: GRPCRoute
```

It can match:

``` text
Service = yages.Echo
Method  = Ping
```

## Service

Provides a stable Kubernetes endpoint for the backend Pods.

------------------------------------------------------------------------

# 4. Lab Directory

Create this directory:

``` bash
mkdir -p ~/k8s-gateway-grpc-canary
cd ~/k8s-gateway-grpc-canary
```

Recommended structure:

``` text
k8s-gateway-grpc-canary/
├── 00-namespace.yaml
├── 01-gatewayclass.yaml
├── 02-gateway.yaml
├── 03-stable.yaml
├── 04-canary.yaml
├── 05-grpc-route.yaml
├── 06-grpc-client.yaml
└── README.md
```

------------------------------------------------------------------------

# 5. Prerequisites

You need:

-   Kubernetes cluster
-   `kubectl`
-   Helm 3
-   `grpcurl`
-   Internet access from the machine installing the controller

Check:

``` bash
kubectl version --client
helm version
grpcurl --version
kubectl get nodes
```

Example expected:

``` text
NAME          STATUS   ROLES           AGE
controlplane  Ready    control-plane   ...
worker        Ready    <none>          ...
```

------------------------------------------------------------------------

# 6. Install grpcurl

## Ubuntu

One option is to download the appropriate grpcurl release binary from
the official grpcurl project.

Or, if your environment already provides grpcurl:

``` bash
grpcurl --version
```

The lab requires a grpcurl client because gRPC is not tested with
ordinary browser `curl` in the same way as HTTP applications.

------------------------------------------------------------------------

# 7. Install Envoy Gateway

This lab pins Envoy Gateway to a documented release instead of using the
moving `latest` development build.

``` bash
helm install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.2 \
  -n envoy-gateway-system \
  --create-namespace
```

Wait for the controller:

``` bash
kubectl wait \
  --timeout=5m \
  -n envoy-gateway-system \
  deployment/envoy-gateway \
  --for=condition=Available
```

Verify:

``` bash
kubectl get pods -n envoy-gateway-system
```

You should see the Envoy Gateway controller running.

Check Gateway API CRDs:

``` bash
kubectl get crd | grep gateway.networking.k8s.io
```

Check the important resources:

``` bash
kubectl api-resources | grep -E 'gateway|grpc'
```

You should find resources such as:

``` text
gatewayclasses
gateways
httproutes
grpcroutes
```

------------------------------------------------------------------------

# 8. File 00 --- Namespace

Create:

``` bash
nano 00-namespace.yaml
```

Content:

``` yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gateway-grpc-demo
```

Apply:

``` bash
kubectl apply -f 00-namespace.yaml
```

Verify:

``` bash
kubectl get ns gateway-grpc-demo
```

------------------------------------------------------------------------

# 9. File 01 --- GatewayClass

Create:

``` bash
nano 01-gatewayclass.yaml
```

Content:

``` yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: grpc-demo-class
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

Apply:

``` bash
kubectl apply -f 01-gatewayclass.yaml
```

Verify:

``` bash
kubectl get gatewayclass
```

Detailed status:

``` bash
kubectl get gatewayclass grpc-demo-class -o yaml
```

Look for:

``` yaml
conditions:
- type: Accepted
  status: "True"
```

### Teaching point

`GatewayClass` answers:

> "Which Gateway controller is responsible for this Gateway?"

------------------------------------------------------------------------

# 10. File 02 --- Gateway

Create:

``` bash
nano 02-gateway.yaml
```

Content:

``` yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: grpc-gateway
  namespace: gateway-grpc-demo
spec:
  gatewayClassName: grpc-demo-class

  listeners:
    - name: grpc
      protocol: HTTP
      port: 80

      allowedRoutes:
        namespaces:
          from: Same
```

Apply:

``` bash
kubectl apply -f 02-gateway.yaml
```

Verify:

``` bash
kubectl get gateway -n gateway-grpc-demo
```

Detailed:

``` bash
kubectl describe gateway grpc-gateway -n gateway-grpc-demo
```

Wait for:

``` text
PROGRAMMED=True
```

and:

``` text
READY=True
```

depending on the controller/status presentation.

------------------------------------------------------------------------

# 11. Why Is the Listener HTTP Instead of GRPC?

This is an important teaching point.

A gRPC request is transported over HTTP/2.

Gateway API uses an HTTP-family listener for this traffic.

The gRPC-specific routing logic is expressed by:

``` yaml
kind: GRPCRoute
```

So the conceptual flow is:

``` text
gRPC
 |
 | HTTP/2
 v
Gateway listener
 |
 v
GRPCRoute
 |
 v
gRPC Service
```

------------------------------------------------------------------------

# 12. File 03 --- Stable Deployment + Service

Create:

``` bash
nano 03-stable.yaml
```

Content:

``` yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grpc-stable
  namespace: gateway-grpc-demo
  labels:
    app: grpc-demo
    version: stable
spec:
  replicas: 2

  selector:
    matchLabels:
      app: grpc-demo
      version: stable

  template:
    metadata:
      labels:
        app: grpc-demo
        version: stable

    spec:
      containers:
        - name: grpc-server
          image: ghcr.io/projectcontour/yages:v0.1.0

          ports:
            - name: grpc
              containerPort: 9000
              protocol: TCP

---
apiVersion: v1
kind: Service
metadata:
  name: grpc-stable
  namespace: gateway-grpc-demo
spec:
  type: ClusterIP

  selector:
    app: grpc-demo
    version: stable

  ports:
    - name: grpc
      port: 9000
      targetPort: 9000
      protocol: TCP
      appProtocol: kubernetes.io/h2c
```

Apply:

``` bash
kubectl apply -f 03-stable.yaml
```

Verify:

``` bash
kubectl get deploy,pods,svc -n gateway-grpc-demo
```

Check endpoints:

``` bash
kubectl get endpointslice \
  -n gateway-grpc-demo \
  -l kubernetes.io/service-name=grpc-stable
```

------------------------------------------------------------------------

# 13. File 04 --- Canary Deployment + Service

Create:

``` bash
nano 04-canary.yaml
```

Content:

``` yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grpc-canary
  namespace: gateway-grpc-demo
  labels:
    app: grpc-demo
    version: canary
spec:
  replicas: 1

  selector:
    matchLabels:
      app: grpc-demo
      version: canary

  template:
    metadata:
      labels:
        app: grpc-demo
        version: canary

    spec:
      containers:
        - name: grpc-server
          image: ghcr.io/projectcontour/yages:v0.1.0

          ports:
            - name: grpc
              containerPort: 9000
              protocol: TCP

---
apiVersion: v1
kind: Service
metadata:
  name: grpc-canary
  namespace: gateway-grpc-demo
spec:
  type: ClusterIP

  selector:
    app: grpc-demo
    version: canary

  ports:
    - name: grpc
      port: 9000
      targetPort: 9000
      protocol: TCP
      appProtocol: kubernetes.io/h2c
```

Apply:

``` bash
kubectl apply -f 04-canary.yaml
```

Verify:

``` bash
kubectl get deploy,pods,svc -n gateway-grpc-demo
```

Check:

``` bash
kubectl get endpointslice \
  -n gateway-grpc-demo \
  -l kubernetes.io/service-name=grpc-canary
```

------------------------------------------------------------------------

# 14. Understand the Two Services

The Services intentionally select different Pods.

Stable:

``` yaml
selector:
  app: grpc-demo
  version: stable
```

Canary:

``` yaml
selector:
  app: grpc-demo
  version: canary
```

Therefore:

``` text
grpc-stable
    |
    +--> grpc-stable Pod 1
    |
    +--> grpc-stable Pod 2


grpc-canary
    |
    +--> grpc-canary Pod 1
```

This is why we can independently control stable and canary traffic at
the Gateway layer.

------------------------------------------------------------------------

# 15. File 05 --- GRPCRoute with 90/10 Canary

Create:

``` bash
nano 05-grpc-route.yaml
```

Content:

``` yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: grpc-canary-route
  namespace: gateway-grpc-demo

spec:
  parentRefs:
    - name: grpc-gateway

  hostnames:
    - grpc-demo.local

  rules:

    - matches:
        - method:
            service: yages.Echo
            method: Ping

      backendRefs:

        - name: grpc-stable
          port: 9000
          weight: 90

        - name: grpc-canary
          port: 9000
          weight: 10
```

Apply:

``` bash
kubectl apply -f 05-grpc-route.yaml
```

------------------------------------------------------------------------

# 16. Understand the GRPCRoute

This section is very important for teaching.

``` yaml
matches:
  - method:
      service: yages.Echo
      method: Ping
```

means:

``` text
gRPC service = yages.Echo
gRPC method  = Ping
```

The route then selects:

``` text
grpc-stable
grpc-canary
```

using weights.

``` text
90 + 10 = 100

Stable = 90 / 100 = approximately 90%
Canary = 10 / 100 = approximately 10%
```

------------------------------------------------------------------------

# 17. Check GRPCRoute Status

Run:

``` bash
kubectl get grpcroute -n gateway-grpc-demo
```

Then:

``` bash
kubectl describe grpcroute grpc-canary-route \
  -n gateway-grpc-demo
```

Or:

``` bash
kubectl get grpcroute grpc-canary-route \
  -n gateway-grpc-demo \
  -o yaml
```

Look for:

``` yaml
conditions:
- type: Accepted
  status: "True"
```

and:

``` yaml
conditions:
- type: ResolvedRefs
  status: "True"
```

If `ResolvedRefs=False`, inspect the referenced Services and ports.

------------------------------------------------------------------------

# 18. Get the Gateway Address

Run:

``` bash
kubectl get gateway grpc-gateway \
  -n gateway-grpc-demo \
  -o jsonpath='{.status.addresses[0].value}'
```

Store it:

``` bash
export GATEWAY_HOST=$(kubectl get gateway grpc-gateway \
  -n gateway-grpc-demo \
  -o jsonpath='{.status.addresses[0].value}')
```

Check:

``` bash
echo $GATEWAY_HOST
```

If the address is an IP such as:

``` text
20.x.x.x
```

you can test it directly.

------------------------------------------------------------------------

# 19. Test gRPC Routing

Use:

``` bash
grpcurl \
  -plaintext \
  -authority=grpc-demo.local \
  ${GATEWAY_HOST}:80 \
  yages.Echo/Ping
```

Expected response:

``` json
{
  "text": "pong"
}
```

The important part is that the request went through:

``` text
grpcurl
   |
   v
Gateway
   |
   v
GRPCRoute
   |
   +---- 90% ---> grpc-stable
   |
   +---- 10% ---> grpc-canary
```

------------------------------------------------------------------------

# 20. Important Note About the YAGES Demo

The YAGES image used in this lab returns the same logical `pong`
response from both backend versions.

That is intentional so that the lab focuses on **Gateway API routing
mechanics**.

For production-style training, you can replace the image with your own
gRPC application where:

``` text
Stable response:
"Hello from STABLE"

Canary response:
"Hello from CANARY"
```

Then the canary split becomes visible directly in the response.

You can also verify backend selection through Gateway/Envoy access logs
and metrics.

------------------------------------------------------------------------

# 21. Optional: Test the Services Directly

Test Stable without the Gateway.

Create a temporary grpcurl Pod:

``` bash
kubectl run grpcurl \
  -n gateway-grpc-demo \
  --rm -it \
  --restart=Never \
  --image=fullstorydev/grpcurl \
  -- \
  -plaintext \
  grpc-stable:9000 \
  yages.Echo/Ping
```

Test Canary:

``` bash
kubectl run grpcurl \
  -n gateway-grpc-demo \
  --rm -it \
  --restart=Never \
  --image=fullstorydev/grpcurl \
  -- \
  -plaintext \
  grpc-canary:9000 \
  yages.Echo/Ping
```

This proves that both Services work before troubleshooting the Gateway.

------------------------------------------------------------------------

# 22. Canary Rollout Exercise

Now change:

``` yaml
weight: 90
```

and:

``` yaml
weight: 10
```

to:

``` yaml
weight: 80
```

and:

``` yaml
weight: 20
```

Apply:

``` bash
kubectl apply -f 05-grpc-route.yaml
```

You now have:

``` text
STABLE  = 80%
CANARY  = 20%
```

------------------------------------------------------------------------

# 23. Canary Progression

Use this teaching sequence.

## Stage 1

``` text
Stable 100%
Canary   0%
```

``` yaml
- name: grpc-stable
  port: 9000
  weight: 100

- name: grpc-canary
  port: 9000
  weight: 0
```

------------------------------------------------------------------------

## Stage 2

``` text
Stable 90%
Canary 10%
```

``` yaml
weight: 90
weight: 10
```

------------------------------------------------------------------------

## Stage 3

``` text
Stable 80%
Canary 20%
```

``` yaml
weight: 80
weight: 20
```

------------------------------------------------------------------------

## Stage 4

``` text
Stable 50%
Canary 50%
```

``` yaml
weight: 50
weight: 50
```

------------------------------------------------------------------------

## Stage 5

``` text
Stable 0%
Canary 100%
```

``` yaml
weight: 0
weight: 100
```

This is a simple **progressive canary rollout**.

------------------------------------------------------------------------

# 24. Quick Weight Commands

Instead of editing the whole YAML manually, you can use:

``` bash
kubectl patch grpcroute grpc-canary-route \
  -n gateway-grpc-demo \
  --type=json \
  -p='[
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":80},
    {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":20}
  ]'
```

Verify:

``` bash
kubectl get grpcroute grpc-canary-route \
  -n gateway-grpc-demo \
  -o yaml
```

------------------------------------------------------------------------

# 25. Generate Many gRPC Requests

Run:

``` bash
for i in $(seq 1 100); do
  grpcurl -plaintext \
    -authority=grpc-demo.local \
    ${GATEWAY_HOST}:80 \
    yages.Echo/Ping >/dev/null
done
```

For a real application that identifies its backend, you would expect
approximately:

``` text
Stable ≈ 80 requests
Canary ≈ 20 requests
```

Do not expect mathematically exact 80/20 distribution for a small
sample.

------------------------------------------------------------------------

# 26. Why the Numbers Are Not Exact

Weights describe a proportional distribution.

For example:

``` yaml
weight: 90
weight: 10
```

means:

``` text
90 / (90 + 10) = 90%

10 / (90 + 10) = 10%
```

But actual observations may look like:

``` text
Stable = 91
Canary = 9
```

or:

``` text
Stable = 87
Canary = 13
```

especially for a small number of requests.

With more traffic, the observed distribution generally becomes closer to
the configured proportion.

------------------------------------------------------------------------

# 27. Service/Method Routing Demo

The route currently matches:

``` yaml
service: yages.Echo
method: Ping
```

Conceptually:

``` text
grpc-demo.local
       |
       v
yages.Echo/Ping
       |
       v
GRPCRoute
       |
       +-------- Stable
       |
       +-------- Canary
```

This is different from ordinary HTTP path routing such as:

``` text
/app1
/app2
```

gRPC routing can understand:

``` text
Service
Method
```

directly.

------------------------------------------------------------------------

# 28. Add a Catch-All gRPC Rule

For a teaching exercise, remove the `matches` section:

``` yaml
rules:
  - backendRefs:
      - name: grpc-stable
        port: 9000
        weight: 90

      - name: grpc-canary
        port: 9000
        weight: 10
```

Now the rule can match gRPC requests without restricting to one
service/method.

Apply:

``` bash
kubectl apply -f 05-grpc-route.yaml
```

Discuss with students:

> When should I use an explicit service/method match versus a catch-all
> route?

------------------------------------------------------------------------

# 29. Gateway API vs Ingress

## Traditional Ingress

``` text
Ingress
   |
   +--> path /app1
   |
   +--> path /app2
```

Ingress is useful for common HTTP/HTTPS use cases.

## Gateway API

``` text
GatewayClass
     |
Gateway
     |
+----+-------------------+
|                        |
HTTPRoute             GRPCRoute
|                        |
HTTP Services        gRPC Services
```

Gateway API provides a richer, role-oriented model and separates
infrastructure configuration from application routing.

------------------------------------------------------------------------

# 30. Who Does What?

  Resource        Responsibility
  --------------- ----------------------------------
  GatewayClass    Selects Gateway controller
  Gateway         Defines network listener
  GRPCRoute       Defines gRPC routing
  Service         Provides stable backend endpoint
  Deployment      Runs backend Pods
  Envoy Gateway   Implements the Gateway API
  Envoy proxy     Receives and forwards traffic
  grpcurl         Generates gRPC test requests

------------------------------------------------------------------------

# 31. End-to-End Request Flow

When this command runs:

``` bash
grpcurl -plaintext \
  -authority=grpc-demo.local \
  ${GATEWAY_HOST}:80 \
  yages.Echo/Ping
```

the flow is:

``` text
1. grpcurl
      |
      | HTTP/2 + gRPC
      v
2. Envoy Gateway Service
      |
      v
3. Envoy Proxy
      |
      v
4. Gateway listener :80
      |
      v
5. GRPCRoute
      |
      | service = yages.Echo
      | method  = Ping
      v
6. Weighted backend selection
      |
      +-----------------------+
      |                       |
      v                       v
  grpc-stable            grpc-canary
    90%                     10%
      |                       |
      v                       v
 Stable Pods              Canary Pod
```

------------------------------------------------------------------------

# 32. Important: Gateway vs Gateway Controller

Do not confuse:

``` text
Gateway API
```

with:

``` text
Envoy Gateway
```

Gateway API is a Kubernetes API standard.

Envoy Gateway is an implementation/controller that watches Gateway API
resources and programs Envoy proxies.

Think:

``` text
Gateway API = language / API model

Envoy Gateway = implementation

Envoy Proxy = data plane
```

------------------------------------------------------------------------

# 33. Troubleshooting

## Problem 1 --- GatewayClass is not Accepted

Run:

``` bash
kubectl describe gatewayclass grpc-demo-class
```

Check Envoy Gateway:

``` bash
kubectl logs \
  -n envoy-gateway-system \
  deployment/envoy-gateway
```

Verify controller name:

``` yaml
controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

------------------------------------------------------------------------

## Problem 2 --- Gateway is not Ready

Run:

``` bash
kubectl describe gateway grpc-gateway \
  -n gateway-grpc-demo
```

Check:

``` bash
kubectl get pods -n envoy-gateway-system
```

Find the generated Envoy Service:

``` bash
kubectl get svc -n envoy-gateway-system
```

------------------------------------------------------------------------

## Problem 3 --- GRPCRoute is not Accepted

Run:

``` bash
kubectl describe grpcroute grpc-canary-route \
  -n gateway-grpc-demo
```

Check:

``` yaml
parentRefs:
  - name: grpc-gateway
```

Make sure the Gateway exists:

``` bash
kubectl get gateway -n gateway-grpc-demo
```

------------------------------------------------------------------------

## Problem 4 --- ResolvedRefs=False

Check Services:

``` bash
kubectl get svc -n gateway-grpc-demo
```

Expected:

``` text
grpc-stable
grpc-canary
```

Check ports:

``` bash
kubectl get svc grpc-stable \
  -n gateway-grpc-demo \
  -o yaml
```

The route uses:

``` yaml
port: 9000
```

The Service must expose:

``` yaml
port: 9000
```

------------------------------------------------------------------------

## Problem 5 --- No Service Endpoints

Run:

``` bash
kubectl get endpointslice \
  -n gateway-grpc-demo
```

Also:

``` bash
kubectl get pods \
  -n gateway-grpc-demo \
  --show-labels
```

Stable Pods need:

``` text
app=grpc-demo
version=stable
```

Canary Pods need:

``` text
app=grpc-demo
version=canary
```

------------------------------------------------------------------------

## Problem 6 --- grpcurl Cannot Connect

Check Gateway address:

``` bash
kubectl get gateway grpc-gateway \
  -n gateway-grpc-demo \
  -o yaml
```

Check Envoy Service:

``` bash
kubectl get svc -n envoy-gateway-system
```

If the Gateway is running in a VM-based cluster and its Service has no
external IP, use port-forward.

Find the generated Envoy Service:

``` bash
kubectl get svc \
  -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-name=grpc-gateway
```

Then:

``` bash
kubectl -n envoy-gateway-system \
  port-forward service/<ENVoy-SERVICE-NAME> 8080:80
```

Use:

``` bash
grpcurl \
  -plaintext \
  -authority=grpc-demo.local \
  localhost:8080 \
  yages.Echo/Ping
```

------------------------------------------------------------------------

# 34. VM / kubeadm Lab Notes

If you are running this on a kubeadm cluster on Azure VMs, the Gateway's
generated Service may depend on your environment.

Check:

``` bash
kubectl get svc -n envoy-gateway-system
```

If using a cloud LoadBalancer:

``` bash
kubectl get svc -n envoy-gateway-system -w
```

If using MetalLB:

``` bash
kubectl get svc -n envoy-gateway-system
```

You may see an external IP assigned by MetalLB.

If no external IP is available, use:

``` bash
kubectl port-forward
```

for classroom testing.

------------------------------------------------------------------------

# 35. Optional: Use MetalLB

If your kubeadm cluster already has MetalLB installed, you can allow the
Envoy Gateway Service to receive a LoadBalancer IP.

Check:

``` bash
kubectl get svc -n envoy-gateway-system
```

Expected pattern:

``` text
NAME                       TYPE           EXTERNAL-IP
envoy-grpc-gateway-xxxxx   LoadBalancer   192.168.x.x
```

Then:

``` bash
export GATEWAY_HOST=<METALLB-IP>
```

Test:

``` bash
grpcurl \
  -plaintext \
  -authority=grpc-demo.local \
  ${GATEWAY_HOST}:80 \
  yages.Echo/Ping
```

------------------------------------------------------------------------

# 36. Production Canary Discussion

A real production rollout could look like:

``` text
Release v1
Stable = 100%
Canary = 0%
       |
       v
Deploy v2
       |
       v
Stable = 95%
Canary = 5%
       |
       v
Observe:
- Error rate
- Latency
- CPU
- Memory
- gRPC status codes
       |
       v
Healthy?
   /       \
 YES       NO
  |         |
  v         v
10%       Rollback
  |
  v
25%
  |
  v
50%
  |
  v
100%
```

------------------------------------------------------------------------

# 37. Canary Rollback

If the canary is unhealthy, immediately send all traffic back to stable:

``` bash
kubectl patch grpcroute grpc-canary-route \
  -n gateway-grpc-demo \
  --type=json \
  -p='[
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":100},
    {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":0}
  ]'
```

Verify:

``` bash
kubectl get grpcroute grpc-canary-route \
  -n gateway-grpc-demo \
  -o yaml
```

Now:

``` text
Stable = 100%
Canary = 0%
```

------------------------------------------------------------------------

# 38. Classroom Exercise 1 --- 90/10 Canary

Students must configure:

``` text
Stable = 90
Canary = 10
```

Then explain:

``` text
Why is the Service not doing the 90/10 split?
Where is the split configured?
```

Expected answer:

``` text
The GRPCRoute performs the traffic distribution through
weighted backendRefs.
```

------------------------------------------------------------------------

# 39. Classroom Exercise 2 --- 80/20

Change to:

``` text
Stable = 80
Canary = 20
```

Verify:

``` bash
kubectl get grpcroute -n gateway-grpc-demo -o yaml
```

------------------------------------------------------------------------

# 40. Classroom Exercise 3 --- Canary Off

Set:

``` text
Stable = 100
Canary = 0
```

Question:

> Is the canary Service deleted?

Answer:

``` text
No.

The Service and Pod can remain running.
The Gateway simply sends zero traffic to the canary backend.
```

------------------------------------------------------------------------

# 41. Classroom Exercise 4 --- Canary Promotion

Progress:

``` text
100/0
   ↓
90/10
   ↓
80/20
   ↓
50/50
   ↓
0/100
```

Ask students:

> At what point would you stop the rollout?

Correct production answer:

> Based on application health, not simply because the configured
> percentage changed.

------------------------------------------------------------------------

# 42. Classroom Exercise 5 --- Break the Canary

Scale canary to zero:

``` bash
kubectl scale deployment grpc-canary \
  -n gateway-grpc-demo \
  --replicas=0
```

Check:

``` bash
kubectl get pods -n gateway-grpc-demo
```

Then inspect:

``` bash
kubectl describe grpcroute grpc-canary-route \
  -n gateway-grpc-demo
```

Discuss:

``` text
What happens when one weighted backend has no endpoints?

Does the Gateway API automatically move that percentage
to the healthy backend?

What status/behavior does the implementation expose?
```

This is an important production troubleshooting discussion. Do not
assume that a configured weight automatically becomes a health-aware
failover policy.

------------------------------------------------------------------------

# 43. Classroom Exercise 6 --- Wrong Service Port

Change:

``` yaml
port: 9000
```

to:

``` yaml
port: 9999
```

Apply:

``` bash
kubectl apply -f 05-grpc-route.yaml
```

Check:

``` bash
kubectl describe grpcroute grpc-canary-route \
  -n gateway-grpc-demo
```

Discuss:

``` text
ResolvedRefs
UnsupportedProtocol
backend reference
```

------------------------------------------------------------------------

# 44. Cleanup

Delete the application:

``` bash
kubectl delete -f 06-grpc-client.yaml --ignore-not-found
kubectl delete -f 05-grpc-route.yaml
kubectl delete -f 04-canary.yaml
kubectl delete -f 03-stable.yaml
kubectl delete -f 02-gateway.yaml
kubectl delete -f 01-gatewayclass.yaml
kubectl delete -f 00-namespace.yaml
```

Delete Envoy Gateway:

``` bash
helm uninstall eg -n envoy-gateway-system
```

Optionally:

``` bash
kubectl delete namespace envoy-gateway-system
```

> Be careful when deleting shared Gateway API CRDs. In a teaching
> cluster, they may be used by other labs. Do not blindly delete
> provider-managed or shared Gateway API CRDs.

------------------------------------------------------------------------

# 45. Complete Apply Sequence

Once all files are created:

``` bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-gatewayclass.yaml
kubectl apply -f 02-gateway.yaml
kubectl apply -f 03-stable.yaml
kubectl apply -f 04-canary.yaml
kubectl apply -f 05-grpc-route.yaml
```

Verify everything:

``` bash
kubectl get gatewayclass
kubectl get gateway -n gateway-grpc-demo
kubectl get grpcroute -n gateway-grpc-demo
kubectl get deploy -n gateway-grpc-demo
kubectl get pods -n gateway-grpc-demo
kubectl get svc -n gateway-grpc-demo
kubectl get endpointslice -n gateway-grpc-demo
```

------------------------------------------------------------------------

# 46. One-Command Verification Set

``` bash
echo "===== GatewayClass ====="
kubectl get gatewayclass

echo "===== Gateway ====="
kubectl get gateway -n gateway-grpc-demo

echo "===== GRPCRoute ====="
kubectl get grpcroute -n gateway-grpc-demo

echo "===== Deployments ====="
kubectl get deploy -n gateway-grpc-demo

echo "===== Pods ====="
kubectl get pods -n gateway-grpc-demo -o wide

echo "===== Services ====="
kubectl get svc -n gateway-grpc-demo

echo "===== EndpointSlices ====="
kubectl get endpointslice -n gateway-grpc-demo
```

------------------------------------------------------------------------

# 47. Key Teaching Summary

Remember:

``` text
GatewayClass
    ↓
Gateway
    ↓
GRPCRoute
    ↓
Weighted backendRefs
    ↓
Services
    ↓
Pods
```

For this lab:

``` text
                grpc-demo.local
                       |
                       v
                 grpc-gateway
                       |
                       v
                GRPCRoute
              yages.Echo/Ping
                       |
             +---------+---------+
             |                   |
           90%                 10%
             |                   |
             v                   v
       grpc-stable          grpc-canary
             |                   |
             v                   v
       Stable Pods          Canary Pod
```

------------------------------------------------------------------------

# 48. Interview Questions

### Q1. What is Gateway API?

A Kubernetes API model for expressing traffic infrastructure and routing
configuration using resources such as `GatewayClass`, `Gateway`, and
route types.

### Q2. What is Envoy Gateway?

An implementation/controller that watches Gateway API resources and
configures Envoy proxy infrastructure.

### Q3. What is `GRPCRoute`?

A Gateway API route designed specifically for gRPC traffic.

### Q4. Why prefer `GRPCRoute` over `HTTPRoute` for gRPC?

Because `GRPCRoute` can express gRPC service/method matching directly
and provides gRPC-specific routing semantics.

### Q5. Where is the canary split configured?

In the route's weighted `backendRefs`.

### Q6. Does `weight: 10` mean exactly 10 requests out of every 100?

No. It defines a proportional traffic distribution. Actual observed
percentages vary, especially with small samples.

### Q7. Can Stable and Canary use separate Services?

Yes. This is a clean pattern because each Service selects its own
version-labeled Pods.

### Q8. Can Canary weight be zero?

Yes. A weight of zero means that backend should receive no traffic for
that route rule.

### Q9. What is the role of the Service?

It provides a stable Kubernetes backend abstraction over Pods.

### Q10. What is the role of the Gateway?

It represents the network entry point and listener configuration.

------------------------------------------------------------------------

# 49. Useful Commands Cheat Sheet

``` bash
# Gateway API resources
kubectl api-resources | grep gateway

# GatewayClasses
kubectl get gatewayclass

# Gateways
kubectl get gateway -A

# GRPCRoutes
kubectl get grpcroute -A

# Gateway details
kubectl describe gateway grpc-gateway -n gateway-grpc-demo

# Route details
kubectl describe grpcroute grpc-canary-route -n gateway-grpc-demo

# Pods
kubectl get pods -n gateway-grpc-demo -o wide

# Services
kubectl get svc -n gateway-grpc-demo

# EndpointSlices
kubectl get endpointslice -n gateway-grpc-demo

# Envoy Gateway controller
kubectl get pods -n envoy-gateway-system

# Controller logs
kubectl logs -n envoy-gateway-system deployment/envoy-gateway

# Gateway YAML/status
kubectl get gateway grpc-gateway \
  -n gateway-grpc-demo -o yaml

# GRPCRoute YAML/status
kubectl get grpcroute grpc-canary-route \
  -n gateway-grpc-demo -o yaml
```

------------------------------------------------------------------------

# 50. Official References

-   Kubernetes Gateway API: https://gateway-api.sigs.k8s.io/

-   Gateway API `GRPCRoute`:
    https://gateway-api.sigs.k8s.io/reference/api-types/grpcroute/

-   Gateway API traffic splitting:
    https://gateway-api.sigs.k8s.io/guides/user-guides/traffic-splitting/

-   Envoy Gateway: https://gateway.envoyproxy.io/

-   Envoy Gateway Helm installation:
    https://gateway.envoyproxy.io/docs/install/install-helm/

-   Envoy Gateway gRPC routing:
    https://gateway.envoyproxy.io/latest/tasks/traffic/grpc-routing/

-   YAGES gRPC example: https://github.com/projectcontour/yages

------------------------------------------------------------------------

# 51. Final Teaching Message

The easiest way to remember the complete design is:

``` text
                    CONTROL PLANE
                    =============

             Gateway API resources
                       |
             +---------+---------+
             |                   |
        GatewayClass          GRPCRoute
             |                   |
             +---------+---------+
                       |
                 Envoy Gateway
                       |
                       v

                    DATA PLANE
                    ==========

                    Envoy Proxy
                       |
                       | gRPC / HTTP2
                       v
                 Weighted Routing
                  /            \
                 /              \
              90%                10%
               |                  |
               v                  v
         Stable Service      Canary Service
               |                  |
               v                  v
         Stable Pods          Canary Pods
```

**Core idea:**

> Gateway API defines the desired traffic behavior.\
> Envoy Gateway implements that behavior.\
> Envoy Proxy handles the live traffic.\
> `GRPCRoute` understands gRPC service/method routing.\
> Weighted `backendRefs` provide a simple and powerful mechanism for
> progressive canary traffic shifting.
