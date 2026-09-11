# Kubernetes Remote Access Fix Script

Regenerates the Kubernetes **API Server TLS certificate** so the cluster can be
reached from outside the Azure VNet (e.g. your laptop) using the VM's **public
IP**, then produces a ready-to-download kubeconfig for that remote access.

> Save the script as, for example, `k8s-remote-access-fix.sh`. The instructions
> below use that name.

---

## The problem it solves

The Kubernetes API Server presents a TLS certificate that is only valid for the
addresses listed in its **Subject Alternative Names (SANs)**. A default kubeadm
install usually lists the node's *private* IP, the service IP, and `127.0.0.1` —
but **not** the VM's public IP.

So when your laptop points kubectl at `https://PUBLIC-IP:6443`, TLS verification
fails:

```
x509: certificate is valid for 10.x.x.x, not 20.x.x.x
```

This script rebuilds the API Server certificate with the public IP added to the
SAN list, so remote TLS verification succeeds.

---

## What the script does (in order)

1. Prompts you for the **Azure VM public IP**.
2. Auto-detects the VM's **private IP** (`hostname -I`, first address).
3. Writes a kubeadm config at `/root/kubeadm-config.yaml` with `certSANs` =
   public IP + private IP + `127.0.0.1`.
4. **Backs up** the current `apiserver.crt` / `apiserver.key` to
   `/root/k8s-backup/` with a timestamp.
5. Removes the old API Server cert/key (forces regeneration).
6. Regenerates only the API Server cert via
   `kubeadm init phase certs apiserver`.
7. Restarts `kubelet` and waits ~30s for the control plane to come back.
8. Prints the new certificate's SAN entries so you can confirm the public IP is
   present.
9. Copies `admin.conf` to `/home/azure/admin.conf`, rewrites the server URL to
   the public IP, and locks it down (`chown azure`, `chmod 600`).
10. Runs a health check (`kubectl get nodes`, `kubectl get pods -A`).

It does **not** run `kubeadm reset` or `kubeadm init` — your cluster is not
reinitialized, and only the API Server certificate is touched. All other PKI
(CA, etcd, other component certs) is left alone.

---

## Prerequisites

- A **kubeadm-based** cluster (this uses kubeadm cert phases).
- Run **as `root`** on the **control-plane node**.
- A Linux user named **`azure`** must exist on the VM — step 9 writes to
  `/home/azure` and `chown azure:azure`. If your admin user has a different name,
  edit the two `/home/azure/...` paths and the `chown` line before running.
- **Inbound firewall access to TCP 6443.** In Azure, add a Network Security
  Group (NSG) inbound rule allowing your laptop's IP to reach port `6443` on the
  VM. The cert fix alone does nothing if the port is blocked.
- `kubeadm`, `kubectl`, `openssl`, and `systemctl` available (standard on a
  kubeadm control-plane node).

---

## How to use it

### On the control-plane node

```bash
# 1. Copy the script to the VM and make it executable
chmod +x k8s-remote-access-fix.sh

# 2. Run it as root
sudo ./k8s-remote-access-fix.sh
```

You'll be prompted:

```
Enter Azure VM Public IP: 20.10.30.40
```

Enter your VM's public IP and press Enter. The script then runs steps 1–10 and,
on success, prints the location of the generated kubeconfig and the exact `scp`
command to fetch it.

### On your laptop

```bash
# 3. Download the kubeconfig (command is printed by the script)
scp azure@20.10.30.40:/home/azure/admin.conf ./cluster1.yaml

# 4. Test remote access
kubectl --kubeconfig ./cluster1.yaml get nodes
```

### Use `kubectl` directly (no `--kubeconfig` flag)

Passing `--kubeconfig ./cluster1.yaml` on every command gets tedious. Point the
`KUBECONFIG` environment variable at the file once, then run kubectl normally:

```bash
export KUBECONFIG=$PWD/cluster1.yaml     # use the absolute path of the file
kubectl get pods
kubectl get pods -A                      # pods in all namespaces
kubectl get nodes
```

**Note:** `export` only lasts for the current terminal session. Open a new
terminal and you'll need to export again (or use one of the permanent options
below).

#### Make it permanent (survives new terminals)

Pick **one** of these:

**Option A — add the export to your shell profile**

```bash
# bash
echo 'export KUBECONFIG=$HOME/cluster1.yaml' >> ~/.bashrc
source ~/.bashrc

# zsh (default on macOS)
echo 'export KUBECONFIG=$HOME/cluster1.yaml' >> ~/.zshrc
source ~/.zshrc
```

(Adjust the path to wherever you saved `cluster1.yaml`.)

**Option B — make it kubectl's default config (no env var at all)**

```bash
mkdir -p ~/.kube
cp ./cluster1.yaml ~/.kube/config    # kubectl reads ~/.kube/config automatically
kubectl get pods
```

If you already have a `~/.kube/config` for other clusters, merge instead of
overwriting so you don't lose them:

```bash
KUBECONFIG=~/.kube/config:$PWD/cluster1.yaml kubectl config view --flatten > ~/.kube/config.merged
mv ~/.kube/config.merged ~/.kube/config
kubectl config get-contexts        # list clusters
kubectl config use-context <name>  # switch between them
```

#### Set a default namespace (optional)

`kubectl get pods` shows the `default` namespace unless you say otherwise. To
target, say, `dev` by default:

```bash
kubectl config set-context --current --namespace=dev
kubectl get pods            # now lists pods in dev
```

---

## Verifying it worked

The script already prints the SANs, but you can re-check anytime on the node:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout \
  | grep -A2 "Subject Alternative Name"
```

You should see the public IP listed, e.g.:

```
X509v3 Subject Alternative Name:
    IP Address:20.10.30.40, IP Address:10.0.1.4, IP Address:127.0.0.1
```

---

## If something goes wrong (rollback)

The original certificate and key were backed up in step 4. To restore:

```bash
sudo ls -t /root/k8s-backup/            # find the latest timestamped backup
sudo cp /root/k8s-backup/apiserver.crt.bak.<TIMESTAMP> /etc/kubernetes/pki/apiserver.crt
sudo cp /root/k8s-backup/apiserver.key.bak.<TIMESTAMP> /etc/kubernetes/pki/apiserver.key
sudo systemctl restart kubelet
```

Because the script uses `set -e`, it aborts on the first failing command rather
than continuing in a half-changed state.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|--------|--------------------|
| `x509: certificate is valid for <private>, not <public>` | Public IP not in SANs — re-run the script and enter the correct public IP. |
| Laptop `kubectl` hangs / connection timed out | Port `6443` not open — add an Azure NSG inbound rule for your laptop IP. |
| `chown: invalid user: 'azure:azure'` | No `azure` user — create one, or edit the paths/`chown` to your admin user. |
| API server doesn't come back after restart | Wait longer, then check `sudo crictl ps` / `journalctl -u kubelet`; if needed, roll back (above). |
| Public IP changed later (VM restarted without a static IP) | Re-run the script with the new IP, or assign a static public IP in Azure. |

---

## Security notes — read before using in production

- **`admin.conf` is cluster-admin.** The generated `cluster1.yaml` grants full
  control of the entire cluster. Treat it like a root password: keep it at
  `chmod 600`, never commit it to git, and don't share it. For anything beyond a
  personal lab, create a **scoped user** (a namespaced Role/RoleBinding or a
  read-only ClusterRole) and hand that out instead of the admin kubeconfig.
- **Don't expose 6443 to the whole internet.** Restrict the NSG rule to your
  specific source IP/CIDR. An open API Server is a common attack target.
- Consider access via a bastion/VPN or an SSH tunnel
  (`ssh -L 6443:127.0.0.1:6443 azure@PUBLIC_IP`) instead of opening the port
  publicly.
- This is best suited to **lab / learning / single-admin** setups. Managed
  offerings (AKS) handle API endpoint exposure for you.
