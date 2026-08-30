# Kubernetes API Proxy Server — Production-Grade Setup Without Kubeconfig

## 1. Objective

This lab demonstrates how to access a Kubernetes cluster API through a dedicated **NGINX reverse proxy**, without copying or loading the Kubernetes `admin.conf` / kubeconfig on the client.

### Kubernetes Cluster

```text
VM1
Control Plane
    |
    +-- kube-apiserver :6443
    +-- etcd
    +-- controller-manager
    +-- scheduler

VM2
Worker
    |
    +-- kubelet
    +-- containerd
    +-- Pods

VM3
Proxy Server
    |
    +-- NGINX :443
```

Client:

```text
Laptop
   |
   | HTTPS :443
   v
VM3 - NGINX
   |
   | HTTPS :6443
   v
VM1 - kube-apiserver
   |
   v
Kubernetes RBAC
```

---

# 2. Final Architecture

```text
                         CLIENT / LAPTOP
                               |
                               |
                        HTTPS :443
                               |
                               v
                    +--------------------+
                    |    VM3 - NGINX     |
                    |                    |
                    | Reverse Proxy      |
                    | TLS                |
                    | Rate Limiting      |
                    | Access Control      |
                    +---------+----------+
                              |
                              |
                       HTTPS :6443
                              |
                              v
                +-------------------------+
                | VM1 - CONTROL PLANE    |
                |                         |
                | kube-apiserver :6443   |
                | etcd                    |
                | scheduler               |
                | controller-manager       |
                +-----------+-------------+
                            |
                            |
                     Kubernetes API
                            |
                            v
                +-------------------------+
                | VM2 - WORKER            |
                |                         |
                | kubelet                 |
                | containerd              |
                | Pods                    |
                +-------------------------+
```

---

# 3. VM Information

Replace the example IP addresses with your actual private IP addresses.

```text
VM1 - Control Plane

Private IP:
10.0.1.4

Kubernetes API:
https://10.0.1.4:6443
```

```text
VM2 - Worker

Private IP:
10.0.1.5
```

```text
VM3 - NGINX Proxy

Private IP:
10.0.1.6
```

Client:

```text
Laptop
```

> VM3 is recommended as a separate proxy VM. Do not install the reverse proxy on the Kubernetes control-plane node unless you have a specific reason to do so.

---

# 4. Prerequisites

The Kubernetes cluster should already be working.

From VM1:

```bash
kubectl get nodes
```

Expected:

```text
NAME           STATUS   ROLES           AGE
controlplane   Ready    control-plane   ...
node01         Ready    <none>          ...
```

Verify:

```bash
kubectl get pods -A
```

---

# 5. Verify Kubernetes API Server

Run on VM1:

```bash
kubectl cluster-info
```

Example:

```text
Kubernetes control plane is running at https://10.0.1.4:6443
```

Check the API server:

```bash
ss -lntp | grep 6443
```

Expected:

```text
LISTEN ... 0.0.0.0:6443
```

or:

```text
LISTEN ... 10.0.1.4:6443
```

---

# 6. Test API Server From Worker

From VM2:

```bash
curl -k https://10.0.1.4:6443/version
```

You should receive Kubernetes version information.

Example:

```json
{
  "major": "1",
  "minor": "30",
  ...
}
```

This proves:

```text
VM2
 |
 | HTTPS
 v
VM1:6443
 |
 v
kube-apiserver
```

---

# 7. Network Requirements

The following connectivity is required:

```text
Laptop
   |
   | TCP 443
   v
VM3
```

VM3 must reach:

```text
VM3
 |
 | TCP 6443
 v
VM1
```

The worker needs normal Kubernetes cluster connectivity.

---

# 8. Firewall / NSG Rules

If these are Azure VMs, configure the appropriate NSG/firewall rules.

Recommended:

```text
Source       Destination       Port       Purpose

Laptop       VM3                443        HTTPS Proxy

VM3          VM1                 6443       Kubernetes API
```

Do NOT expose:

```text
Internet → VM1:6443
```

unless there is a specific reason and appropriate security controls.

Preferred:

```text
Internet
   |
   | 443
   v
VM3
   |
   | 6443
   v
VM1
```

---

# 9. Install NGINX on VM3

SSH into VM3.

Update packages:

```bash
sudo apt update
```

Install NGINX:

```bash
sudo apt install -y nginx
```

Check:

```bash
nginx -v
```

Check service:

```bash
systemctl status nginx
```

Enable it:

```bash
sudo systemctl enable nginx
```

---

# 10. Test NGINX

From your laptop:

```bash
curl http://<VM3_PUBLIC_IP>
```

You should receive the NGINX welcome page.

---

# 11. Obtain the Kubernetes CA Certificate

The proxy needs to verify the Kubernetes API server's TLS certificate.

On VM1:

```bash
sudo cp /etc/kubernetes/pki/ca.crt /tmp/kubernetes-ca.crt
```

Copy it securely to VM3:

```bash
scp /tmp/kubernetes-ca.crt user@10.0.1.6:/tmp/
```

On VM3:

```bash
sudo mkdir -p /etc/nginx/kubernetes
```

Move the certificate:

```bash
sudo mv /tmp/kubernetes-ca.crt \
  /etc/nginx/kubernetes/ca.crt
```

Set permissions:

```bash
sudo chmod 644 /etc/nginx/kubernetes/ca.crt
```

---

# 12. Test API TLS Verification

From VM3:

```bash
curl \
  --cacert /etc/nginx/kubernetes/ca.crt \
  https://10.0.1.4:6443/version
```

If certificate verification fails because the API server certificate does not contain the IP address you are using, inspect the certificate:

```bash
openssl x509 \
  -in /etc/kubernetes/pki/apiserver.crt \
  -text \
  -noout
```

Look at:

```text
X509v3 Subject Alternative Name
```

The address/name used by the proxy must match a SAN in the API-server certificate.

---

# 13. Create a Kubernetes ServiceAccount

We don't want the proxy to use:

```text
admin.conf
```

and we don't want to give it:

```text
cluster-admin
```

Instead, create a dedicated identity.

On VM1:

```bash
kubectl create namespace k8s-proxy
```

Create:

```bash
vim proxy-rbac.yaml
```

Add:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-proxy
  namespace: k8s-proxy

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
    verbs:
      - get
      - list
      - watch

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-proxy
  namespace: default
subjects:
  - kind: ServiceAccount
    name: api-proxy
    namespace: k8s-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
```

Apply:

```bash
kubectl apply -f proxy-rbac.yaml
```

---

# 14. Verify RBAC

Check:

```bash
kubectl auth can-i \
  get pods \
  --as=system:serviceaccount:k8s-proxy:api-proxy \
  -n default
```

Expected:

```text
yes
```

Test Deployment access:

```bash
kubectl auth can-i \
  get deployments \
  --as=system:serviceaccount:k8s-proxy:api-proxy \
  -n default
```

Expected:

```text
no
```

This proves that the identity has limited permissions.

---

# 15. Generate a ServiceAccount Token

For testing:

```bash
kubectl create token api-proxy \
  -n k8s-proxy
```

Copy the returned token.

Example:

```text
eyJhbGciOiJSUzI1NiIs...
```

Store it temporarily:

```bash
export TOKEN='<token>'
```

---

# 16. Test Token Directly Against API Server

From VM3:

```bash
curl \
  --cacert /etc/nginx/kubernetes/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://10.0.1.4:6443/api
```

Expected:

```json
{
  "kind": "APIVersions",
  ...
}
```

Now test Pods:

```bash
curl \
  --cacert /etc/nginx/kubernetes/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://10.0.1.4:6443/api/v1/namespaces/default/pods
```

You should receive Pod information.

---

# 17. Test RBAC Restriction

Try accessing Deployments:

```bash
curl \
  --cacert /etc/nginx/kubernetes/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://10.0.1.4:6443/apis/apps/v1/namespaces/default/deployments
```

Expected:

```text
403 Forbidden
```

This proves:

```text
Authentication
       |
       v
ServiceAccount
       |
       v
RBAC
       |
       +---- Pods       → ALLOWED
       |
       +---- Pods/log   → ALLOWED
       |
       +---- Deployments → DENIED
```

---

# 18. Configure NGINX Reverse Proxy

On VM3:

```bash
sudo vim /etc/nginx/sites-available/kubernetes-api
```

Add:

```nginx
server {
    listen 443 ssl;
    server_name k8s-api.example.com;

    ssl_certificate     /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    location / {
        proxy_pass https://10.0.1.4:6443;

        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/nginx/kubernetes/ca.crt;

        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;

        proxy_http_version 1.1;

        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
```

---

# 19. Important NGINX Configuration

The following line forwards the client's Bearer token:

```nginx
proxy_set_header Authorization $http_authorization;
```

Therefore:

```text
Laptop
 |
 | Authorization: Bearer TOKEN
 v
NGINX
 |
 | Authorization: Bearer TOKEN
 v
kube-apiserver
 |
 v
Authentication
 |
 v
RBAC
```

NGINX is not replacing Kubernetes authorization.

The Kubernetes API server still performs the authorization.

---

# 20. Create NGINX Site

Enable the configuration:

```bash
sudo ln -s \
  /etc/nginx/sites-available/kubernetes-api \
  /etc/nginx/sites-enabled/kubernetes-api
```

Remove the default site if necessary:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

Test configuration:

```bash
sudo nginx -t
```

Expected:

```text
syntax is ok
test is successful
```

Restart:

```bash
sudo systemctl restart nginx
```

---

# 21. TLS Certificate for NGINX

For production, use a certificate trusted by your clients.

Example:

```text
/etc/nginx/tls/server.crt
/etc/nginx/tls/server.key
```

The certificate should contain:

```text
k8s-api.example.com
```

as a Subject Alternative Name.

Do not use:

```text
ssl_certificate ...
```

with an unprotected private key.

Set permissions:

```bash
sudo chmod 600 /etc/nginx/tls/server.key
sudo chmod 644 /etc/nginx/tls/server.crt
```

---

# 22. DNS

Create a DNS record:

```text
k8s-api.example.com
        |
        v
VM3 Public IP
```

Then:

```bash
nslookup k8s-api.example.com
```

or:

```bash
dig k8s-api.example.com
```

---

# 23. Test Proxy Without Kubeconfig

From your laptop:

```bash
curl \
  --cacert proxy-ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/api
```

Test Pods:

```bash
curl \
  --cacert proxy-ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/api/v1/namespaces/default/pods
```

The traffic flow is now:

```text
Laptop
 |
 | HTTPS :443
 | Bearer Token
 v
VM3
NGINX
 |
 | HTTPS :6443
 | Bearer Token
 v
VM1
kube-apiserver
 |
 v
RBAC
 |
 v
Pods
```

---

# 24. Verify Worker Is Working

On VM1:

```bash
kubectl get nodes
```

Expected:

```text
NAME           STATUS   ROLES
controlplane   Ready    control-plane
node01         Ready    <none>
```

Create a test Pod:

```bash
kubectl run nginx \
  --image=nginx:latest
```

Check:

```bash
kubectl get pods -o wide
```

Example:

```text
NAME    READY   STATUS    IP            NODE
nginx   1/1     Running   10.244.x.x    node01
```

This confirms the complete cluster:

```text
VM1
Control Plane
    |
    v
API Server
    |
    v
VM2
Worker
    |
    v
nginx Pod
```

---

# 25. Verify API Through Proxy

From laptop:

```bash
curl \
  --cacert proxy-ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/api/v1/namespaces/default/pods
```

The response should contain the `nginx` Pod.

This proves:

```text
Laptop
   |
   v
NGINX
   |
   v
kube-apiserver
   |
   v
RBAC
   |
   v
Pod running on VM2
```

---

# 26. Test Unauthorized Access

Try without a token:

```bash
curl \
  --cacert proxy-ca.crt \
  https://k8s-api.example.com/api/v1/namespaces/default/pods
```

Expected:

```text
401 Unauthorized
```

This proves authentication is required.

---

# 27. Test Forbidden Access

Use the valid token:

```bash
curl \
  --cacert proxy-ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/apis/apps/v1/namespaces/default/deployments
```

Expected:

```text
403 Forbidden
```

Why?

Because:

```text
Token
  |
  v
Authenticated
  |
  v
RBAC
  |
  v
Deployment permission?
  |
  v
NO
  |
  v
403 Forbidden
```

---

# 28. Three Important Tests

## Test 1 — No Token

```bash
curl https://k8s-api.example.com/api
```

Result:

```text
401 Unauthorized
```

---

## Test 2 — Valid Token + Allowed Resource

```bash
curl \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/api/v1/namespaces/default/pods
```

Result:

```text
200 OK
```

---

## Test 3 — Valid Token + Unauthorized Resource

```bash
curl \
  -H "Authorization: Bearer $TOKEN" \
  https://k8s-api.example.com/apis/apps/v1/namespaces/default/deployments
```

Result:

```text
403 Forbidden
```

This is an excellent classroom demonstration of:

```text
401 = Authentication problem

403 = Authorization / RBAC problem
```

---

# 29. Important Security Design

Do NOT use:

```text
admin.conf
```

for this proxy.

Do NOT give the proxy:

```text
cluster-admin
```

Do NOT expose:

```text
VM1:6443
```

directly to the Internet.

Use:

```text
Client
  |
  | 443
  v
NGINX
  |
  | 6443 private
  v
API Server
```

---

# 30. Production Improvements

The basic lab above demonstrates the architecture.

For production, add:

```text
                    Internet
                       |
                       v
                 WAF / Firewall
                       |
                       v
                 Load Balancer
                       |
              +--------+--------+
              |                 |
              v                 v
          NGINX-01          NGINX-02
              |                 |
              +--------+--------+
                       |
                       v
                 API Server LB
                       |
             +---------+---------+
             |         |         |
             v         v         v
          Master1   Master2   Master3
```

Additional controls:

```text
TLS
+
mTLS where appropriate
+
OIDC / Enterprise Identity
+
RBAC
+
Network restrictions
+
Rate limiting
+
Audit logging
+
Monitoring
+
High availability
```

---

# 31. Better Production Authentication

For a real organization, avoid giving every user a shared ServiceAccount token.

Use an identity provider:

```text
User
 |
 v
Microsoft Entra ID / Keycloak / Okta
 |
 v
OIDC
 |
 v
Kubernetes API
 |
 v
RBAC
```

For example:

```text
Ashutosh
   |
   v
Identity Provider
   |
   v
Authenticated identity
   |
   v
Kubernetes RBAC
   |
   +---- get pods       ✓
   +---- get services   ✓
   +---- delete pods    ✗
   +---- create deploy  ✗
```

This provides individual identity and better auditing.

---

# 32. Why Not `kubectl proxy`?

Do not confuse this architecture with:

```bash
kubectl proxy
```

`kubectl proxy` is primarily intended as a local proxy to the Kubernetes API.

Our architecture is:

```text
Dedicated VM
     |
     v
NGINX
     |
     v
kube-apiserver
```

This is suitable as a foundation for a controlled API gateway/reverse-proxy architecture.

---

# 33. Optional: Use `kubectl` Without a kubeconfig

If the goal is specifically to run `kubectl` without loading:

```text
~/.kube/config
```

you can provide connection information explicitly:

```bash
kubectl \
  --server=https://k8s-api.example.com \
  --certificate-authority=proxy-ca.crt \
  --token="$TOKEN" \
  get pods
```

No kubeconfig file is loaded.

The requirements still exist:

```text
API endpoint
+
TLS trust
+
Authentication
```

They are simply supplied through command-line arguments instead of kubeconfig.

---

# 34. Verify No kubeconfig Is Being Used

Check:

```bash
echo $KUBECONFIG
```

If empty, kubectl normally looks for its default configuration.

For a completely explicit test:

```bash
kubectl \
  --kubeconfig=/dev/null \
  --server=https://k8s-api.example.com \
  --certificate-authority=proxy-ca.crt \
  --token="$TOKEN" \
  get pods
```

This demonstrates that the command is not using your normal kubeconfig.

---

# 35. Complete Request Flow

```text
                     LAPTOP
                       |
                       |
                  HTTPS :443
                       |
                       v
              +----------------+
              | VM3            |
              | NGINX          |
              |                |
              | TLS            |
              | Rate Limit     |
              | Access Control |
              +-------+--------+
                      |
                      |
                 HTTPS :6443
                      |
                      v
              +----------------+
              | VM1            |
              | Control Plane   |
              |                |
              | API Server     |
              +-------+--------+
                      |
                      v
                Authentication
                      |
                      v
                    RBAC
                      |
                      v
              +----------------+
              | VM2            |
              | Worker         |
              |                |
              | nginx Pod      |
              +----------------+
```

---

# 36. Troubleshooting

## NGINX cannot connect to API server

From VM3:

```bash
nc -vz 10.0.1.4 6443
```

Expected:

```text
Connection succeeded
```

If it fails, check:

```text
Azure NSG
Ubuntu UFW
Routing
kube-apiserver listening address
```

---

## TLS error

Test:

```bash
curl \
  --cacert /etc/nginx/kubernetes/ca.crt \
  https://10.0.1.4:6443/version
```

Inspect API certificate:

```bash
openssl x509 \
  -in /etc/kubernetes/pki/apiserver.crt \
  -text \
  -noout
```

Check:

```text
Subject Alternative Name
```

---

## 401 Unauthorized

Check:

```text
Authorization header
Bearer token
Token validity
```

Example:

```bash
curl \
  -H "Authorization: Bearer $TOKEN" \
  ...
```

---

## 403 Forbidden

Authentication worked, but RBAC denied the request.

Check:

```bash
kubectl auth can-i \
  get pods \
  --as=system:serviceaccount:k8s-proxy:api-proxy
```

---

## NGINX configuration error

Run:

```bash
sudo nginx -t
```

Then:

```bash
sudo journalctl -u nginx -xe
```

---

# 37. Final Validation Checklist

```text
[ ] VM1 Control Plane is Ready

[ ] VM2 Worker is Ready

[ ] kube-apiserver is listening on 6443

[ ] VM3 can reach VM1:6443

[ ] VM3 has Kubernetes CA certificate

[ ] NGINX is installed

[ ] NGINX TLS is configured

[ ] NGINX forwards Authorization header

[ ] ServiceAccount exists

[ ] RBAC permissions are restricted

[ ] Valid token can access Pods

[ ] Invalid/no token gets 401

[ ] Unauthorized resource gets 403

[ ] VM1:6443 is not publicly exposed

[ ] Client does not need admin.conf

[ ] Client can access API through VM3
```

---

# 38. Final Architecture to Remember

```text
              NO KUBECONFIG
                    |
                    v
                 LAPTOP
                    |
                    | HTTPS 443
                    v
            +---------------+
            | VM3           |
            | NGINX         |
            |               |
            | Reverse Proxy |
            +-------+-------+
                    |
                    | HTTPS 6443
                    | Private Network
                    v
            +---------------+
            | VM1           |
            | CONTROL PLANE |
            |               |
            | API SERVER    |
            +-------+-------+
                    |
                    | Kubernetes API
                    v
                  RBAC
                    |
                    v
            +---------------+
            | VM2           |
            | WORKER        |
            |               |
            | Pods          |
            +---------------+
```

## Key Concept

```text
Kubeconfig is NOT the Kubernetes API.

Kubeconfig is a client configuration file containing:
    |
    +-- API server endpoint
    +-- TLS configuration
    +-- Authentication information

The client can provide those pieces through other mechanisms.

Production architecture:

Client
  ↓
HTTPS
  ↓
Reverse Proxy / Load Balancer
  ↓
kube-apiserver
  ↓
Authentication
  ↓
Authorization / RBAC
  ↓
Kubernetes resources
```

For a **real production deployment**, the next step would be replacing the demo ServiceAccount token with **OIDC (for example, Microsoft Entra ID or Keycloak), adding an HA proxy layer, audit logging, rate limiting, and strict network controls**.