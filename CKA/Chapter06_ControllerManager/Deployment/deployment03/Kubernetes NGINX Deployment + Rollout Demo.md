# Kubernetes NGINX Dashboard — Deployment & Rollout Demo

A hands-on Kubernetes demo that deploys an NGINX web application with:

* Kubernetes Deployment
* ConfigMap
* NodePort Service
* Downward API
* Dynamic Pod information
* Browser access
* `curl` access
* Rolling Updates
* Deployment revisions
* Change causes
* Rollback
* Scaling

The web page displays the **actual Pod name**, Pod IP, Node name, Namespace, application version, and other Kubernetes information.

---

# 1. Project Structure

Create the following files:

```text
.
├── index.html
├── configmap.yaml
├── deployment.yaml
├── service.yaml
└── README.md
```

### File Purpose

| File              | Purpose                                   |
| ----------------- | ----------------------------------------- |
| `index.html`      | Beautiful NGINX dashboard                 |
| `configmap.yaml`  | Stores the HTML as a Kubernetes ConfigMap |
| `deployment.yaml` | Creates and manages NGINX Pods            |
| `service.yaml`    | Exposes NGINX using NodePort              |
| `README.md`       | Complete demo instructions                |

---

# 2. Architecture

```text
                         KUBERNETES CLUSTER
                                |
                                |
                       +------------------+
                       |    Deployment    |
                       |    nginx-demo    |
                       +--------+---------+
                                |
              +-----------------+-----------------+
              |                 |                 |
              v                 v                 v
        +-----------+     +-----------+     +-----------+
        |   Pod 1   |     |   Pod 2   |     |   Pod 3   |
        |   NGINX   |     |   NGINX   |     |   NGINX   |
        +-----+-----+     +-----+-----+     +-----+-----+
              |                 |                 |
              +-----------------+-----------------+
                                |
                                v
                     +----------------------+
                     |       Service        |
                     |       NodePort       |
                     |        :30080        |
                     +----------+-----------+
                                |
                       +--------+--------+
                       |                 |
                       v                 v
                    Browser            curl
```

---

# 3. Create the HTML Page

Create:

```bash
vim index.html
```

The HTML page should contain placeholders such as:

```text
POD_NAME
POD_IP
NODE_NAME
NAMESPACE
APP_VERSION
```

These values will be replaced by the NGINX container when it starts.

Example:

```text
Pod Name          : POD_NAME
Pod IP            : POD_IP
Node Name         : NODE_NAME
Namespace         : NAMESPACE
Application Ver.  : APP_VERSION
```

---

# 4. Create ConfigMap from index.html

Instead of manually putting hundreds of lines of HTML inside YAML, generate the ConfigMap from `index.html`.

Run:

```bash
kubectl create configmap nginx-html \
  --from-file=index.html \
  --dry-run=client -o yaml > configmap.yaml
```

Check:

```bash
cat configmap.yaml
```

---

# 5. Validate ConfigMap

Before applying:

```bash
kubectl apply --dry-run=client -f configmap.yaml
```

Expected:

```text
configmap/nginx-html created (dry run)
```

---

# 6. Deployment

Create:

```bash
vim deployment.yaml
```

The Deployment should contain:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nginx-demo

  annotations:
    kubernetes.io/change-cause: "Initial deployment"

spec:
  replicas: 3

  revisionHistoryLimit: 10

  selector:
    matchLabels:
      app: nginx-demo

  template:

    metadata:
      labels:
        app: nginx-demo

    spec:

      containers:

        - name: nginx

          image: nginx:alpine

          ports:

            - containerPort: 80

          env:

            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP

            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName

            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace

            - name: APP_VERSION
              value: "v1"

          command:

            - /bin/sh

            - -c

          args:

            - |
              cp /config/index.html /usr/share/nginx/html/index.html
              sed -i "s/POD_NAME/${POD_NAME}/g" /usr/share/nginx/html/index.html
              sed -i "s/POD_IP/${POD_IP}/g" /usr/share/nginx/html/index.html
              sed -i "s/NODE_NAME/${NODE_NAME}/g" /usr/share/nginx/html/index.html
              sed -i "s/NAMESPACE/${NAMESPACE}/g" /usr/share/nginx/html/index.html
              sed -i "s/APP_VERSION/${APP_VERSION}/g" /usr/share/nginx/html/index.html
              nginx -g "daemon off;"

          volumeMounts:

            - name: html
              mountPath: /config

      volumes:

        - name: html

          configMap:

            name: nginx-html
```

---

# 7. Validate Deployment YAML

Run:

```bash
kubectl apply --dry-run=client -f deployment.yaml
```

Expected:

```text
deployment.apps/nginx-demo created (dry run)
```

---

# 8. Create the Service

Create:

```bash
vim service.yaml
```

Use:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: nginx-demo-service

spec:

  type: NodePort

  selector:
    app: nginx-demo

  ports:

    - name: http

      port: 80

      targetPort: 80

      nodePort: 30080
```

---

# 9. Validate Service

```bash
kubectl apply --dry-run=client -f service.yaml
```

Expected:

```text
service/nginx-demo-service created (dry run)
```

---

# 10. Deploy the Application

Apply the ConfigMap:

```bash
kubectl apply -f configmap.yaml
```

Apply the Deployment:

```bash
kubectl apply -f deployment.yaml
```

Apply the Service:

```bash
kubectl apply -f service.yaml
```

Or:

```bash
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

---

# 11. Check Deployment

```bash
kubectl get deployment nginx-demo
```

Expected:

```text
NAME         READY   UP-TO-DATE   AVAILABLE
nginx-demo   3/3     3            3
```

---

# 12. Check Pods

```bash
kubectl get pods -l app=nginx-demo
```

Example:

```text
NAME                          READY   STATUS    RESTARTS   AGE
nginx-demo-7d8f9c6b5d-abc12   1/1     Running   0          1m
nginx-demo-7d8f9c6b5d-def34   1/1     Running   0          1m
nginx-demo-7d8f9c6b5d-ghi56   1/1     Running   0          1m
```

---

# 13. Watch Pods

```bash
kubectl get pods -l app=nginx-demo -w
```

Press:

```text
Ctrl + C
```

to stop.

---

# 14. Check Service

```bash
kubectl get service nginx-demo-service
```

Expected:

```text
NAME                 TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)
nginx-demo-service   NodePort   10.96.x.x     <none>        80:30080/TCP
```

The important part is:

```text
80:30080/TCP
```

---

# 15. Get Node IP

```bash
kubectl get nodes -o wide
```

Example:

```text
NAME     STATUS   ROLES    INTERNAL-IP
node01   Ready    <none>   172.30.1.10
```

Use the node's IP:

```text
172.30.1.10
```

---

# 16. Test Using curl

From a machine that can reach the Kubernetes node:

```bash
curl http://172.30.1.10:30080
```

Or:

```bash
curl http://NODE-IP:30080
```

The dashboard HTML will be returned.

---

# 17. Open in Browser

Open:

```text
http://NODE-IP:30080
```

Example:

```text
http://172.30.1.10:30080
```

The same application can be accessed from both:

```text
Browser
   |
   +---- http://NODE-IP:30080


curl
   |
   +---- curl http://NODE-IP:30080
```

---

# 18. Pod Name on the Page

The dashboard displays the actual Pod name.

For example:

```text
Pod Name : nginx-demo-7d8f9c6b5d-abc12
```

The value comes from the Kubernetes Downward API:

```yaml
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
```

---

# 19. Pod IP

The Pod IP is obtained using:

```yaml
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
```

The page can display:

```text
Pod IP : 10.244.1.15
```

---

# 20. Node Name

The Node name is obtained using:

```yaml
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
```

Example:

```text
Node Name : node01
```

---

# 21. Namespace

The namespace is obtained using:

```yaml
- name: NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
```

Example:

```text
Namespace : default
```

---

# 22. Check Environment Variables

Find a Pod:

```bash
kubectl get pods -l app=nginx-demo
```

Then:

```bash
kubectl exec -it <POD-NAME> -- env
```

Look for:

```text
POD_NAME=nginx-demo-xxxxx
POD_IP=10.244.x.x
NODE_NAME=node01
NAMESPACE=default
APP_VERSION=v1
```

---

# 23. Check HTML Inside Pod

```bash
kubectl exec -it <POD-NAME> -- cat /usr/share/nginx/html/index.html
```

The placeholders should have been replaced.

For example:

```text
POD_NAME
```

becomes:

```text
nginx-demo-7d8f9c6b5d-abc12
```

---

# 24. Check Revision History

Run:

```bash
kubectl rollout history deployment nginx-demo
```

Example:

```text
deployment.apps/nginx-demo

REVISION  CHANGE-CAUSE
1         Initial deployment
```

---

# 25. What Is a Deployment Revision?

Every time the **Pod template changes**, Kubernetes creates a new Deployment revision.

For example:

```yaml
- name: APP_VERSION
  value: "v1"
```

Change to:

```yaml
- name: APP_VERSION
  value: "v2"
```

This changes the Pod template.

Kubernetes creates:

```text
Deployment
     |
     +---- ReplicaSet v1
     |
     +---- ReplicaSet v2
```

---

# 26. Change Cause

The annotation:

```yaml
kubernetes.io/change-cause: "Initial deployment"
```

is displayed in:

```bash
kubectl rollout history deployment nginx-demo
```

Example:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to v2
3         Updated dashboard to v3
```

---

# 27. Version 2

Edit:

```bash
vim deployment.yaml
```

Change:

```yaml
annotations:
  kubernetes.io/change-cause: "Initial deployment"
```

to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v2"
```

Also change:

```yaml
- name: APP_VERSION
  value: "v1"
```

to:

```yaml
- name: APP_VERSION
  value: "v2"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

# 28. Watch Version 2 Rollout

```bash
kubectl rollout status deployment nginx-demo
```

Expected:

```text
deployment "nginx-demo" successfully rolled out
```

Watch Pods:

```bash
kubectl get pods -l app=nginx-demo -w
```

You will see new Pods being created.

---

# 29. Check Revision History

```bash
kubectl rollout history deployment nginx-demo
```

Expected:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
```

---

# 30. View Revision 1

```bash
kubectl rollout history deployment nginx-demo --revision=1
```

---

# 31. View Revision 2

```bash
kubectl rollout history deployment nginx-demo --revision=2
```

---

# 32. Create Version 3

Edit:

```bash
vim deployment.yaml
```

Change:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v2"
```

to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated application to version v3"
```

Change:

```yaml
- name: APP_VERSION
  value: "v2"
```

to:

```yaml
- name: APP_VERSION
  value: "v3"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

---

# 33. Check Version 3 History

```bash
kubectl rollout history deployment nginx-demo
```

Expected:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
3         Updated application to version v3
```

---

# 34. Rollback to Previous Revision

```bash
kubectl rollout undo deployment nginx-demo
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

---

# 35. Rollback to Specific Revision

For example, rollback to revision 2:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

Then:

```bash
kubectl rollout status deployment nginx-demo
```

---

# 36. Important: Rollback Creates a New Revision

Suppose history is:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
3         Updated application to version v3
```

If you run:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

the result may become:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated application to version v2
3         Updated application to version v3
4         Updated application to version v2
```

Rollback does **not** simply delete revision 3.

Kubernetes creates a new revision using the old Pod template.

---

# 37. Test After Rollback

Check Pods:

```bash
kubectl get pods -l app=nginx-demo
```

Then:

```bash
curl http://NODE-IP:30080
```

Open:

```text
http://NODE-IP:30080
```

The page should show the application version corresponding to the rolled-back Pod template.

---

# 38. Change the HTML Page

Edit:

```bash
vim index.html
```

For example, change:

```text
Kubernetes - NGINX Web Server
```

to:

```text
Kubernetes - NGINX Web Server - VERSION 2
```

Save the file.

---

# 39. Recreate ConfigMap

After modifying `index.html`, regenerate:

```bash
kubectl create configmap nginx-html \
  --from-file=index.html \
  --dry-run=client -o yaml > configmap.yaml
```

Apply:

```bash
kubectl apply -f configmap.yaml
```

---

# 40. Restart Deployment

Because the container copies the ConfigMap into the NGINX web directory when it starts, restart the Deployment:

```bash
kubectl rollout restart deployment nginx-demo
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

---

# 41. Important Difference: ConfigMap vs Deployment Revision

Changing:

```text
index.html
```

and applying:

```bash
kubectl apply -f configmap.yaml
```

changes the ConfigMap.

It does **not necessarily create a Deployment revision**.

A Deployment revision is created when the Deployment's Pod template changes.

For example:

```yaml
APP_VERSION: v1
```

to:

```yaml
APP_VERSION: v2
```

changes the Pod template.

Therefore:

```text
HTML change
    |
    v
ConfigMap change
    |
    v
No Deployment revision automatically


Deployment template change
    |
    v
New ReplicaSet
    |
    v
New Deployment revision
```

---

# 42. Check ReplicaSets

```bash
kubectl get rs
```

Example:

```text
NAME                    DESIRED   CURRENT   READY
nginx-demo-abc123       0         0         0
nginx-demo-def456       3         3         3
```

Each Deployment revision is associated with a ReplicaSet.

---

# 43. Describe Deployment

```bash
kubectl describe deployment nginx-demo
```

This shows:

* Desired replicas
* Current replicas
* Available replicas
* Pod template
* ReplicaSets
* Conditions
* Events

---

# 44. Check Deployment Revision Annotation

Run:

```bash
kubectl get deployment nginx-demo -o yaml
```

Look for:

```yaml
deployment.kubernetes.io/revision: "3"
```

---

# 45. Scale Up

Scale from 3 to 5:

```bash
kubectl scale deployment nginx-demo --replicas=5
```

Check:

```bash
kubectl get pods -l app=nginx-demo
```

You should now have 5 Pods.

---

# 46. Scale Down

Scale back to 3:

```bash
kubectl scale deployment nginx-demo --replicas=3
```

Check:

```bash
kubectl get deployment nginx-demo
```

---

# 47. See Which Pod Is Serving the Request

Because the page displays the Pod name, run:

```bash
curl http://NODE-IP:30080
```

You may see:

```text
Pod Name : nginx-demo-abc123
```

Run the command again:

```bash
curl http://NODE-IP:30080
```

You may get:

```text
Pod Name : nginx-demo-def456
```

The Service can distribute requests between the available Pods.

---

# 48. View All Pods

```bash
kubectl get pods -l app=nginx-demo -o wide
```

Example:

```text
NAME                          READY   STATUS    IP            NODE
nginx-demo-abc123             1/1     Running   10.244.1.10   node01
nginx-demo-def456             1/1     Running   10.244.1.11   node01
nginx-demo-ghi789             1/1     Running   10.244.1.12   node01
```

---

# 49. Complete Versioning Demo

## Version 1

In `deployment.yaml`:

```yaml
annotations:
  kubernetes.io/change-cause: "Initial deployment"
```

and:

```yaml
- name: APP_VERSION
  value: "v1"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

## Version 2

Change to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated NGINX dashboard to version v2"
```

and:

```yaml
- name: APP_VERSION
  value: "v2"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

## Version 3

Change to:

```yaml
annotations:
  kubernetes.io/change-cause: "Updated NGINX dashboard to version v3"
```

and:

```yaml
- name: APP_VERSION
  value: "v3"
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

# 50. View Complete History

```bash
kubectl rollout history deployment nginx-demo
```

Example:

```text
REVISION  CHANGE-CAUSE
1         Initial deployment
2         Updated NGINX dashboard to version v2
3         Updated NGINX dashboard to version v3
```

---

# 51. Rollback Demo

Rollback to revision 2:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

Check Pods:

```bash
kubectl get pods
```

Test:

```bash
curl http://NODE-IP:30080
```

Browser:

```text
http://NODE-IP:30080
```

Check history again:

```bash
kubectl rollout history deployment nginx-demo
```

---

# 52. Useful Commands

## Deployment

```bash
kubectl get deployment nginx-demo
```

## Pods

```bash
kubectl get pods -l app=nginx-demo
```

## Pods with Node information

```bash
kubectl get pods -l app=nginx-demo -o wide
```

## Service

```bash
kubectl get svc nginx-demo-service
```

## Deployment details

```bash
kubectl describe deployment nginx-demo
```

## Pod details

```bash
kubectl describe pod <POD-NAME>
```

## Rollout status

```bash
kubectl rollout status deployment nginx-demo
```

## Rollout history

```bash
kubectl rollout history deployment nginx-demo
```

## Specific revision

```bash
kubectl rollout history deployment nginx-demo --revision=2
```

## Rollback

```bash
kubectl rollout undo deployment nginx-demo
```

## Rollback to specific revision

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

## Restart

```bash
kubectl rollout restart deployment nginx-demo
```

## ReplicaSets

```bash
kubectl get rs
```

## Scale

```bash
kubectl scale deployment nginx-demo --replicas=5
```

## Node information

```bash
kubectl get nodes -o wide
```

---

# 53. Complete Demo Command Sequence

```bash
# Create ConfigMap
kubectl create configmap nginx-html \
  --from-file=index.html \
  --dry-run=client -o yaml > configmap.yaml

# Deploy
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# Check
kubectl get deployment
kubectl get pods
kubectl get svc

# Get Node IP
kubectl get nodes -o wide

# Test
curl http://NODE-IP:30080

# Check history
kubectl rollout history deployment nginx-demo
```

---

# 54. Version 2 Command Sequence

Edit:

```bash
vim deployment.yaml
```

Change:

```yaml
value: "v1"
```

to:

```yaml
value: "v2"
```

Change the change cause:

```yaml
kubernetes.io/change-cause: "Updated application to version v2"
```

Then:

```bash
kubectl apply -f deployment.yaml

kubectl rollout status deployment nginx-demo

kubectl rollout history deployment nginx-demo
```

---

# 55. Version 3 Command Sequence

Edit:

```bash
vim deployment.yaml
```

Change:

```yaml
value: "v2"
```

to:

```yaml
value: "v3"
```

Change:

```yaml
kubernetes.io/change-cause: "Updated application to version v3"
```

Then:

```bash
kubectl apply -f deployment.yaml

kubectl rollout status deployment nginx-demo

kubectl rollout history deployment nginx-demo
```

---

# 56. Rollback Command Sequence

View history:

```bash
kubectl rollout history deployment nginx-demo
```

Rollback to revision 2:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

Check:

```bash
kubectl rollout status deployment nginx-demo
```

Check Pods:

```bash
kubectl get pods
```

Test:

```bash
curl http://NODE-IP:30080
```

---

# 57. Final Architecture

```text
                         index.html
                             |
                             |
                             v
                    +----------------+
                    |   ConfigMap    |
                    |   nginx-html   |
                    +-------+--------+
                            |
                            |
                            v
                    +----------------+
                    |   Deployment   |
                    |   nginx-demo   |
                    +-------+--------+
                            |
                +-----------+-----------+
                |           |           |
                v           v           v
              Pod 1       Pod 2       Pod 3
                |           |           |
                +-----------+-----------+
                            |
                            v
                     NodePort :30080
                            |
                    +-------+-------+
                    |               |
                    v               v
                 Browser          curl
```

---

# 58. Key Concepts Learned

### ConfigMap

Stores the HTML configuration:

```text
index.html
    |
    v
ConfigMap
```

### Deployment

Manages:

```text
Pods
ReplicaSets
Rolling Updates
Revisions
Rollback
Scaling
```

### Service

Provides stable access to Pods:

```text
NodePort :30080
```

### Downward API

Provides Pod metadata:

```text
Pod Name
Pod IP
Node Name
Namespace
```

### Rolling Update

Changes Pods gradually instead of stopping the whole application.

### Revision

Represents a version of the Deployment Pod template.

### Change Cause

Describes why a revision was created:

```text
Initial deployment
Updated application to v2
Updated application to v3
```

### Rollback

Returns the application to an earlier Pod template:

```bash
kubectl rollout undo deployment nginx-demo --to-revision=2
```

### Scaling

Changes the number of replicas:

```bash
kubectl scale deployment nginx-demo --replicas=5
```

---

# 59. Final Cleanup

Delete the Service:

```bash
kubectl delete -f service.yaml
```

Delete the Deployment:

```bash
kubectl delete -f deployment.yaml
```

Delete the ConfigMap:

```bash
kubectl delete -f configmap.yaml
```

Or delete everything:

```bash
kubectl delete -f .
```

---

# 60. One-Line Summary

```text
index.html
    ↓
ConfigMap
    ↓
Deployment
    ↓
NGINX Pods
    ↓
NodePort Service
    ↓
Browser / curl

Deployment template change
    ↓
New ReplicaSet
    ↓
New Revision
    ↓
Rolling Update
    ↓
Rollback when required
```

**This demo covers the complete Kubernetes Deployment lifecycle: create → expose → access → update → rollout → revision → rollback → scale.**
