#!/usr/bin/env bash
# =============================================================================
#  setup-nfs.sh  —  ONE script to wire NFS into the 3-node demo cluster
# =============================================================================
#
#  Modes
#  -----
#   sudo ./setup-nfs.sh server              # on the NFS server (control-plane node)
#   sudo ./setup-nfs.sh client [NFS_IP]     # on every worker (installs nfs-common, test-mounts)
#        ./setup-nfs.sh k8s    <NFS_IP>     # anywhere kubectl works: CSI driver + StorageClasses
#   sudo WORKERS="ubuntu@k8s-w1 ubuntu@k8s-w2" ./setup-nfs.sh all
#                                           # on control plane: server + clients (via ssh) + k8s
#
#  Environment overrides
#  ---------------------
#   NFS_SERVER          IP clients/k8s should use       (default: auto-detected primary IP)
#   ALLOWED_CIDR        subnet allowed to mount          (default: auto-detected, e.g. 192.168.56.0/24)
#   NFS_ROOT            base export dir                  (default: /srv/nfs)
#   CSI_NFS_VERSION     csi-driver-nfs release           (default: v4.13.2)
#   LOCAL_PATH_VERSION  rancher local-path release       (default: v0.0.37)
#
#  What it creates
#  ---------------
#   /srv/nfs/kubedata         -> dynamic volumes (StorageClass "nfs-csi")  — RWX / RWOP / RWO demos
#   /srv/nfs/static/website   -> pre-populated content                     — ROX demo
#   StorageClass nfs-csi      -> provisioner nfs.csi.k8s.io
#   StorageClass local-path   -> rancher local-path (node-local disk)      — "real" RWO demo
# =============================================================================
set -euo pipefail

NFS_ROOT="${NFS_ROOT:-/srv/nfs}"
DYN_DIR="$NFS_ROOT/kubedata"
STATIC_DIR="$NFS_ROOT/static"
CSI_NFS_VERSION="${CSI_NFS_VERSION:-v4.13.2}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.37}"
SC_NAME="nfs-csi"

log()  { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Mode '$1' must be run with sudo."; }

detect_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}
detect_cidr() {
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] && ip -4 route show dev "$dev" proto kernel scope link | awk '{print $1; exit}'
}

# -----------------------------------------------------------------------------
# server: install nfs-kernel-server, create + export directories
# -----------------------------------------------------------------------------
cmd_server() {
  need_root server
  local cidr="${ALLOWED_CIDR:-$(detect_cidr || true)}"
  [[ -n "$cidr" ]] || die "Could not detect subnet. Re-run with ALLOWED_CIDR=192.168.56.0/24"

  log "Installing NFS server packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nfs-kernel-server nfs-common >/dev/null

  log "Creating export directories under $NFS_ROOT"
  mkdir -p "$DYN_DIR" "$STATIC_DIR/website"

  log "Pre-populating content for the ROX (ReadOnlyMany) demo"
  cat > "$STATIC_DIR/website/index.html" <<'EOF'
<!doctype html>
<html><body style="font-family:sans-serif">
  <h1>Hello from a ReadOnlyMany volume</h1>
  <p>This file lives on the NFS server at /srv/nfs/static/website.</p>
  <p>Every nginx pod on every worker node mounts it <b>read-only</b>.</p>
</body></html>
EOF
  echo "Published by the platform team. Pods may read me but never change me." \
    > "$STATIC_DIR/website/about.txt"

  chown -R nobody:nogroup "$NFS_ROOT"
  chmod 0777 "$DYN_DIR"                       # demo-friendly; tighten for real use
  chmod -R a+rX "$STATIC_DIR"

  log "Writing /etc/exports.d/k8s-demo.exports (allowed: $cidr)"
  mkdir -p /etc/exports.d
  cat > /etc/exports.d/k8s-demo.exports <<EOF
# no_root_squash is required by csi-driver-nfs (it creates/deletes per-PV subdirs as root)
$DYN_DIR    $cidr(rw,sync,no_subtree_check,no_root_squash)
# Exported rw ON PURPOSE: the ROX demo shows that read-only must be enforced by Kubernetes
$STATIC_DIR $cidr(rw,sync,no_subtree_check,no_root_squash)
EOF

  systemctl enable --now nfs-kernel-server >/dev/null
  exportfs -ra

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    log "ufw is active — opening NFS (2049) and rpcbind (111) for $cidr"
    ufw allow from "$cidr" to any port 2049 proto tcp >/dev/null
    ufw allow from "$cidr" to any port 111 >/dev/null
  fi

  log "Active exports:"
  exportfs -v
  log "NFS server ready on $(detect_ip)"
}

# -----------------------------------------------------------------------------
# client: install nfs-common (needed by kubelet for in-tree `nfs:` volumes) + test
# -----------------------------------------------------------------------------
cmd_client() {
  need_root client
  local srv="${1:-${NFS_SERVER:-}}"

  log "Installing nfs-common on $(hostname)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nfs-common >/dev/null

  if [[ -n "$srv" ]]; then
    log "Test-mounting $srv:$DYN_DIR"
    mkdir -p /mnt/nfs-test
    mount -t nfs -o nfsvers=4.1 "$srv:$DYN_DIR" /mnt/nfs-test
    touch "/mnt/nfs-test/.probe-$(hostname)" && rm -f "/mnt/nfs-test/.probe-$(hostname)"
    umount /mnt/nfs-test
    log "Read/write test against $srv OK"
  else
    warn "No NFS server IP given — skipped test mount"
  fi
}

# -----------------------------------------------------------------------------
# k8s: csi-driver-nfs + StorageClass nfs-csi + local-path provisioner
# -----------------------------------------------------------------------------
cmd_k8s() {
  local srv="${1:-${NFS_SERVER:-}}"
  [[ -n "$srv" ]] || die "Usage: $0 k8s <NFS_SERVER_IP>"
  command -v kubectl >/dev/null || die "kubectl not found"
  command -v curl    >/dev/null || die "curl not found"

  if [[ -z "${KUBECONFIG:-}" && ! -f "$HOME/.kube/config" && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
  kubectl get nodes >/dev/null || die "kubectl cannot reach the cluster"

  log "Installing csi-driver-nfs $CSI_NFS_VERSION"
  curl -fsSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${CSI_NFS_VERSION}/deploy/install-driver.sh" \
    | bash -s "$CSI_NFS_VERSION" --
  kubectl -n kube-system rollout status deploy/csi-nfs-controller --timeout=300s
  kubectl -n kube-system rollout status ds/csi-nfs-node         --timeout=300s

  log "Creating StorageClass '$SC_NAME' -> $srv:$DYN_DIR"
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $SC_NAME
provisioner: nfs.csi.k8s.io
parameters:
  server: $srv
  share: $DYN_DIR
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
EOF

  log "Installing local-path-provisioner $LOCAL_PATH_VERSION (node-local RWO storage)"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s

  local env_file
  env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/demo.env"
  echo "NFS_SERVER=$srv" > "$env_file"
  [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$env_file" || true
  log "Saved $env_file"

  kubectl get storageclass
  log "Cluster storage ready. Start with demo 01 in README.md"
}

# -----------------------------------------------------------------------------
# all: server here, clients over ssh, then k8s
# -----------------------------------------------------------------------------
cmd_all() {
  need_root all
  local srv="${NFS_SERVER:-$(detect_ip)}"
  [[ -n "$srv" ]] || die "Could not detect this node's IP; set NFS_SERVER=..."

  cmd_server
  cmd_client "$srv"   # control plane gets nfs-common too

  if [[ -z "${WORKERS:-}" ]]; then
    warn "WORKERS not set — run 'sudo ./setup-nfs.sh client $srv' on each worker yourself"
  else
    for w in $WORKERS; do
      log "Configuring client on $w over ssh"
      ssh -o StrictHostKeyChecking=accept-new "$w" "sudo NFS_SERVER=$srv bash -s -- client" < "${BASH_SOURCE[0]}"
    done
  fi

  cmd_k8s "$srv"
}

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  server) shift; cmd_server "$@" ;;
  client) shift; cmd_client "$@" ;;
  k8s)    shift; cmd_k8s "$@" ;;
  all)    shift; cmd_all "$@" ;;
  *)      usage ;;
esac
