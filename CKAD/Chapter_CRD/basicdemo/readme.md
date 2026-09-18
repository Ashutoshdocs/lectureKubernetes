# Kubernetes CRD Practical — Complete Hands-On Demo

This practical demonstrates **Kubernetes CustomResourceDefinitions (CRDs)** from start to finish.

You will:

1. Understand the CRD → Custom Resource relationship
2. Create a CRD
3. Inspect the CRD
4. Create custom resources (CRs)
5. Read, edit, patch, and delete CRs
6. Use labels and selectors
7. Validate custom resource schema
8. Observe Kubernetes API discovery
9. Add a short status subresource demo
10. Clean up everything

---

## 1. What Are We Building?

We will create our own Kubernetes API resource called:

```text
webapps.example.com
```

A custom resource will look like:

```yaml
apiVersion: example.com/v1
kind: WebApp
metadata:
  name: frontend
spec:
  image: nginx:1.27
  replicas: 3
  port: 80
```

The important idea is:

```text
CRD
 │
 │ defines a new API type
 ▼
WebApp
 │
 ├── frontend
 ├── backend
 └── payments
```

A **CRD is the definition/schema of a new Kubernetes resource type**.

A **Custom Resource (CR)** is an actual object created from that type.

---

# 2. Prerequisites

You need:

- A working Kubernetes cluster
- `kubectl`
- Cluster-admin or sufficient permissions to create CRDs

Check the cluster:

```bash
kubectl version --client
kubectl cluster-info
kubectl get nodes
```

Optional:

```bash
kubectl get namespaces
```

---

# 3. Create a Working Directory

Linux/macOS:

```bash
mkdir -p k8s-crd-demo
cd k8s-crd-demo
```

Windows PowerShell:

```powershell
mkdir k8s-crd-demo
cd k8s-crd-demo
```

---

# 4. Create the CRD

Create:

```text
webapp-crd.yaml
```

Content:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.example.com
spec:
  group: example.com

  names:
    plural: webapps
    singular: webapp
    kind: WebApp
    shortNames:
      - wa

  scope: Namespaced

  versions:
    - name: v1
      served: true
      storage: true

      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                image:
                  type: string

                replicas:
                  type: integer
                  minimum: 1
                  maximum: 10

                port:
                  type: integer
                  minimum: 1
                  maximum: 65535
```

---

# 5. Understand the CRD YAML

## API version

```yaml
apiVersion: apiextensions.k8s.io/v1
```

This tells Kubernetes that we are creating a:

```text
CustomResourceDefinition
```

---

## Kind

```yaml
kind: CustomResourceDefinition
```

We are defining a new Kubernetes resource type.

---

## CRD name

```yaml
metadata:
  name: webapps.example.com
```

The standard CRD naming pattern is:

```text
<plural>.<group>
```

Therefore:

```text
webapps.example.com
```

means:

```text
plural = webapps
group  = example.com
```

---

# 6. API Group

```yaml
group: example.com
```

Our custom API will eventually look like:

```text
example.com/v1
```

Therefore our custom resource uses:

```yaml
apiVersion: example.com/v1
```

---

# 7. Resource Names

```yaml
names:
  plural: webapps
  singular: webapp
  kind: WebApp
  shortNames:
    - wa
```

These create several ways to refer to the resource.

### Full plural name

```bash
kubectl get webapps
```

### Singular name

```bash
kubectl get webapp
```

### Short name

```bash
kubectl get wa
```

### Kind

```text
WebApp
```

The **kind** is what appears in YAML:

```yaml
kind: WebApp
```

---

# 8. Namespaced vs Cluster-Scoped CRD

We selected:

```yaml
scope: Namespaced
```

That means each WebApp belongs to a namespace.

For example:

```text
default/frontend
dev/frontend
prod/frontend
```

The same name can exist in different namespaces.

If we wanted cluster-scoped resources, we would use:

```yaml
scope: Cluster
```

---

# 9. Create the CRD

Run:

```bash
kubectl apply -f webapp-crd.yaml
```

Expected result:

```text
customresourcedefinition.apiextensions.k8s.io/webapps.example.com created
```

---

# 10. Verify the CRD

```bash
kubectl get crd
```

Or:

```bash
kubectl get crds
```

Filter our CRD:

```bash
kubectl get crd webapps.example.com
```

---

# 11. Describe the CRD

```bash
kubectl describe crd webapps.example.com
```

This is useful for teaching/demo purposes because it shows:

- Group
- Versions
- Scope
- Names
- Conditions
- Schema

---

# 12. Get CRD as YAML

```bash
kubectl get crd webapps.example.com -o yaml
```

You can also use:

```bash
kubectl get crd webapps.example.com -o json
```

---

# 13. Check CRD Status

```bash
kubectl get crd webapps.example.com \
  -o jsonpath='{.status.conditions[*]}'
```

A healthy CRD normally reaches conditions such as:

```text
NamesAccepted
Established
```

A quick check:

```bash
kubectl get crd webapps.example.com \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

---

# 14. Kubernetes API Discovery

Once the CRD is established, Kubernetes exposes an API endpoint for it.

Check API resources:

```bash
kubectl api-resources | grep -i webapp
```

You should see something similar to:

```text
webapps    wa    example.com/v1    true    WebApp
```

Check API versions:

```bash
kubectl api-versions | grep example.com
```

Expected:

```text
example.com/v1
```

---

# 15. Explain the API Endpoint

Because our CRD is:

```text
group: example.com
version: v1
plural: webapps
scope: Namespaced
```

the Kubernetes API path is conceptually:

```text
/apis/example.com/v1/namespaces/<namespace>/webapps
```

For example:

```text
/apis/example.com/v1/namespaces/default/webapps
```

You normally use:

```bash
kubectl
```

instead of manually calling the API.

---

# 16. Create a Custom Resource

Create:

```text
frontend.yaml
```

```yaml
apiVersion: example.com/v1
kind: WebApp

metadata:
  name: frontend
  labels:
    app: frontend
    environment: dev

spec:
  image: nginx:1.27
  replicas: 3
  port: 80
```

Important:

This is **not a Deployment**.

It is our own:

```text
WebApp
```

resource.

---

# 17. Create the Custom Resource

```bash
kubectl apply -f frontend.yaml
```

Expected:

```text
webapp.example.com/frontend created
```

---

# 18. List Custom Resources

```bash
kubectl get webapps
```

Short name:

```bash
kubectl get wa
```

Using singular:

```bash
kubectl get webapp
```

---

# 19. Get All WebApps Across Namespaces

```bash
kubectl get webapps -A
```

or:

```bash
kubectl get wa -A
```

---

# 20. Get a Specific WebApp

```bash
kubectl get webapp frontend
```

More readable:

```bash
kubectl get webapp frontend -o wide
```

---

# 21. Get the Custom Resource as YAML

```bash
kubectl get webapp frontend -o yaml
```

This is one of the most important commands for understanding CRs.

Notice:

```yaml
apiVersion: example.com/v1
kind: WebApp
```

rather than:

```yaml
apiVersion: apps/v1
kind: Deployment
```

---

# 22. Describe the Custom Resource

```bash
kubectl describe webapp frontend
```

This shows:

- Metadata
- Labels
- Spec
- Events
- Status, if present

---

# 23. Get Only the Spec

```bash
kubectl get webapp frontend \
  -o jsonpath='{.spec}'
```

Get image:

```bash
kubectl get webapp frontend \
  -o jsonpath='{.spec.image}'
```

Get replicas:

```bash
kubectl get webapp frontend \
  -o jsonpath='{.spec.replicas}'
```

Get port:

```bash
kubectl get webapp frontend \
  -o jsonpath='{.spec.port}'
```

---

# 24. Create Another Custom Resource

Create:

```text
backend.yaml
```

```yaml
apiVersion: example.com/v1
kind: WebApp

metadata:
  name: backend
  labels:
    app: backend
    environment: dev

spec:
  image: nginx:1.27
  replicas: 2
  port: 8080
```

Apply:

```bash
kubectl apply -f backend.yaml
```

Check:

```bash
kubectl get wa
```

Expected:

```text
NAME       AGE
backend    ...
frontend   ...
```

---

# 25. Create a Production WebApp

Create:

```text
production.yaml
```

```yaml
apiVersion: example.com/v1
kind: WebApp

metadata:
  name: payments
  labels:
    app: payments
    environment: prod

spec:
  image: nginx:1.27
  replicas: 5
  port: 8080
```

Apply:

```bash
kubectl apply -f production.yaml
```

Check:

```bash
kubectl get wa --show-labels
```

---

# 26. Label Selectors

Get development WebApps:

```bash
kubectl get wa \
  -l environment=dev
```

Get production WebApps:

```bash
kubectl get wa \
  -l environment=prod
```

Get frontend:

```bash
kubectl get wa \
  -l app=frontend
```

This demonstrates that CRs participate in normal Kubernetes metadata mechanisms.

---

# 27. Edit a Custom Resource

Run:

```bash
kubectl edit webapp frontend
```

Change:

```yaml
replicas: 3
```

to:

```yaml
replicas: 5
```

Save and exit.

Verify:

```bash
kubectl get webapp frontend -o yaml
```

Or:

```bash
kubectl get webapp frontend \
  -o jsonpath='{.spec.replicas}'
```

Expected:

```text
5
```

---

# 28. Patch a Custom Resource

Patch replicas:

```bash
kubectl patch webapp frontend \
  --type='merge' \
  -p '{"spec":{"replicas":4}}'
```

Verify:

```bash
kubectl get wa frontend \
  -o jsonpath='{.spec.replicas}'
```

Expected:

```text
4
```

Patch image:

```bash
kubectl patch webapp frontend \
  --type='merge' \
  -p '{"spec":{"image":"nginx:1.28"}}'
```

---

# 29. Validation Demo

Our CRD schema says:

```yaml
replicas:
  type: integer
  minimum: 1
  maximum: 10
```

Try an invalid value:

```yaml
apiVersion: example.com/v1
kind: WebApp

metadata:
  name: invalid-webapp

spec:
  image: nginx:1.27
  replicas: 20
  port: 80
```

Save as:

```text
invalid.yaml
```

Run:

```bash
kubectl apply -f invalid.yaml
```

Kubernetes should reject the object because:

```text
replicas > 10
```

---

# 30. Test Invalid Data Type

Try:

```yaml
replicas: "three"
```

instead of:

```yaml
replicas: 3
```

Run:

```bash
kubectl apply -f invalid.yaml
```

The schema expects:

```text
integer
```

not:

```text
string
```

This demonstrates why CRD schemas are important.

---

# 31. Test Port Validation

Our schema says:

```yaml
port:
  type: integer
  minimum: 1
  maximum: 65535
```

Try:

```yaml
port: 70000
```

Apply:

```bash
kubectl apply -f invalid.yaml
```

The API server should reject it.

---

# 32. Delete One Custom Resource

```bash
kubectl delete webapp frontend
```

Verify:

```bash
kubectl get wa
```

---

# 33. Recreate It

```bash
kubectl apply -f frontend.yaml
```

Verify:

```bash
kubectl get wa
```

---

# 34. Delete Using the YAML File

```bash
kubectl delete -f frontend.yaml
```

---

# 35. Delete Multiple Custom Resources

```bash
kubectl delete webapp backend payments
```

Or:

```bash
kubectl delete -f backend.yaml -f production.yaml
```

---

# 36. Delete All WebApps in a Namespace

Be careful with this command:

```bash
kubectl delete webapps --all
```

This deletes all WebApp custom resources in the current namespace.

---

# 37. Important Concept — CRD vs CR

Think of it like this:

```text
CRD
 │
 │ defines
 ▼
WebApp resource type
 │
 ├──────────────┐
 ▼              ▼
CR: frontend    CR: backend
```

CRD:

```yaml
kind: CustomResourceDefinition
```

CR:

```yaml
kind: WebApp
```

The CRD answers:

> What is a WebApp?

The CR answers:

> What is the configuration of this particular WebApp?

---

# 38. Important Concept — CRD Does NOT Automatically Create Pods

This is a critical Kubernetes concept.

After:

```bash
kubectl apply -f frontend.yaml
```

you have:

```text
WebApp object
```

but Kubernetes does **not automatically create**:

```text
Deployment
Pod
Service
```

Check:

```bash
kubectl get pods
```

You should not expect a Pod just because the WebApp CR exists.

Why?

Because a CRD primarily extends the Kubernetes API.

Something else must watch the CR and act on it.

---

# 39. Where Does the Automation Come From?

Normally:

```text
User
 │
 │ kubectl apply
 ▼
API Server
 │
 ▼
WebApp CR
 │
 ▼
Controller / Operator
 │
 ├── creates Deployment
 ├── creates Service
 └── manages application
```

This controller/operator is the part that gives the custom resource behavior.

---

# 40. CRD Without Controller

```text
CRD
 │
 └── creates a new API resource type
```

Example:

```text
WebApp
```

But:

```text
WebApp
 │
 └── no automatic Deployment
```

unless a controller is watching it.

---

# 41. CRD + Controller / Operator

```text
CRD
  │
  ▼
Custom Resource
  │
  ▼
Controller
  │
  ├── Deployment
  ├── Service
  ├── ConfigMap
  └── other resources
```

This is the foundation of the Kubernetes Operator pattern.

---

# 42. Optional Status Subresource Demo

A production-quality CRD often separates:

```text
spec
```

from:

```text
status
```

Conceptually:

```yaml
spec:
  replicas: 3

status:
  readyReplicas: 3
```

The user/controller declares the desired state in:

```text
spec
```

The controller reports observed state in:

```text
status
```

---

# 43. Add Status to the CRD

Edit:

```bash
kubectl edit crd webapps.example.com
```

Under the version definition, add:

```yaml
subresources:
  status: {}
```

For example:

```yaml
versions:
  - name: v1
    served: true
    storage: true

    subresources:
      status: {}

    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              image:
                type: string

              replicas:
                type: integer
                minimum: 1
                maximum: 10

              port:
                type: integer
                minimum: 1
                maximum: 65535
```

For a real project, keep the CRD YAML in source control and re-apply it instead of manually editing the live object.

---

# 44. Add Status Schema

A better production CRD explicitly defines status:

```yaml
schema:
  openAPIV3Schema:
    type: object

    properties:
      spec:
        type: object
        properties:
          image:
            type: string

          replicas:
            type: integer
            minimum: 1
            maximum: 10

          port:
            type: integer
            minimum: 1
            maximum: 65535

      status:
        type: object
        properties:
          phase:
            type: string

          readyReplicas:
            type: integer
```

---

# 45. Inspect the Status

```bash
kubectl get webapp frontend -o yaml
```

You may see:

```yaml
status:
  phase: Running
  readyReplicas: 3
```

However, remember:

**A CRD does not magically populate status.**

A controller/operator normally updates it.

---

# 46. API Server Raw Endpoint Demo

You can use:

```bash
kubectl proxy
```

Then, from another terminal:

```bash
curl http://127.0.0.1:8001/apis/example.com/v1/namespaces/default/webapps
```

This demonstrates that the CRD has extended the Kubernetes API.

On Windows PowerShell, you can use:

```powershell
Invoke-RestMethod `
  http://127.0.0.1:8001/apis/example.com/v1/namespaces/default/webapps
```

Stop the proxy with:

```text
Ctrl+C
```

---

# 47. Useful CRD Commands Cheat Sheet

## List CRDs

```bash
kubectl get crd
```

## Get one CRD

```bash
kubectl get crd webapps.example.com
```

## Describe CRD

```bash
kubectl describe crd webapps.example.com
```

## CRD YAML

```bash
kubectl get crd webapps.example.com -o yaml
```

## List API resources

```bash
kubectl api-resources
```

## Search for our resource

```bash
kubectl api-resources | grep -i webapp
```

## API versions

```bash
kubectl api-versions
```

## List custom resources

```bash
kubectl get webapps
```

## Short name

```bash
kubectl get wa
```

## All namespaces

```bash
kubectl get wa -A
```

## Get one

```bash
kubectl get wa frontend
```

## YAML

```bash
kubectl get wa frontend -o yaml
```

## JSON

```bash
kubectl get wa frontend -o json
```

## Describe

```bash
kubectl describe wa frontend
```

## Edit

```bash
kubectl edit wa frontend
```

## Patch

```bash
kubectl patch wa frontend \
  --type='merge' \
  -p '{"spec":{"replicas":4}}'
```

## Delete

```bash
kubectl delete wa frontend
```

## Delete from YAML

```bash
kubectl delete -f frontend.yaml
```

---

# 48. Final Cleanup

Delete all WebApp objects:

```bash
kubectl delete webapps --all
```

Delete the CRD:

```bash
kubectl delete crd webapps.example.com
```

Verify:

```bash
kubectl get crd webapps.example.com
```

Expected:

```text
Error from server (NotFound)
```

Check API resources:

```bash
kubectl api-resources | grep -i webapp
```

The WebApp resource should no longer be available.

---

# 49. Important Cleanup Warning

Deleting the CRD also removes the custom resource type and its stored custom resources.

Therefore:

```bash
kubectl delete crd webapps.example.com
```

should be treated as a destructive operation.

Always understand what custom resources depend on a CRD before removing it in a real cluster.

---

# 50. Complete Demo Flow

For teaching, run these commands in order:

```bash
# 1. Check cluster
kubectl get nodes

# 2. Create CRD
kubectl apply -f webapp-crd.yaml

# 3. Verify CRD
kubectl get crd webapps.example.com

# 4. Describe CRD
kubectl describe crd webapps.example.com

# 5. Check API discovery
kubectl api-resources | grep -i webapp

# 6. Check API version
kubectl api-versions | grep example.com

# 7. Create CR
kubectl apply -f frontend.yaml

# 8. List CRs
kubectl get wa

# 9. Inspect CR
kubectl describe wa frontend

# 10. Get CR YAML
kubectl get wa frontend -o yaml

# 11. Get individual fields
kubectl get wa frontend \
  -o jsonpath='{.spec.image}'

kubectl get wa frontend \
  -o jsonpath='{.spec.replicas}'

# 12. Patch CR
kubectl patch wa frontend \
  --type='merge' \
  -p '{"spec":{"replicas":4}}'

# 13. Verify
kubectl get wa frontend -o yaml

# 14. Delete CR
kubectl delete wa frontend

# 15. Delete CRD
kubectl delete crd webapps.example.com
```

---

# 51. Mental Model

Remember this picture:

```text
                  KUBERNETES API
                       │
                       ▼
          CustomResourceDefinition
                       │
             defines "WebApp"
                       │
                       ▼
                  WebApp / v1
                       │
             ┌─────────┼─────────┐
             ▼         ▼         ▼
          frontend   backend   payments
             │
             │
             ▼
        Custom Resource
             │
             │
      ┌──────┴───────┐
      │              │
     spec          status
      │              │
 desired state    observed state
      │              │
      └──────┬───────┘
             │
             ▼
       Controller / Operator
             │
       ┌─────┼──────┐
       ▼     ▼      ▼
   Deployment Service ConfigMap
       │
       ▼
      Pods
```

---

# 52. Key Takeaways

### CRD

```text
Defines a new Kubernetes API resource type.
```

### Custom Resource

```text
An actual object created from that type.
```

### `spec`

```text
Desired configuration/state.
```

### `status`

```text
Observed state, normally maintained by a controller.
```

### CRD alone

```text
Extends the Kubernetes API.
```

### CRD + Controller

```text
Creates Kubernetes automation / operator behavior.
```

### Schema

```text
Controls and validates the shape and values of CR data.
```

### Scope

```text
Namespaced
or
Cluster
```

---

# 53. One-Line Interview Explanation

> **A Kubernetes CRD extends the Kubernetes API by defining a new resource type, while a Custom Resource is an instance of that type; a controller/operator can then watch those resources and implement the desired automation.**
