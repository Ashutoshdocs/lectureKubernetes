#!/usr/bin/env bash
# =============================================================================
#  cluster-setup.sh — bootstrap the 3-node kubeadm cluster used by this demo
#  (skip this file if you already have a 1 control-plane + 2 worker cluster)
# =============================================================================
#
#   On ALL 3 nodes:        sudo ./cluster-setup.sh common
#   On control plane only: sudo ./cluster-setup.sh controlplane
#                          -> prints a `kubeadm join ...` command
#   On each worker:        sudo <paste the join command>
#
#  Tested target: Ubuntu 22.04 / 24.04, 2 vCPU / 2 GB RAM per node minimum.
#  Override: K8S_MINOR=v1.36  POD_CIDR=10.244.0.0/16  CP_IP=<auto>
# =============================================================================
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.36}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"      # matches Flannel's default

log() { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with sudo"

cmd_common() {
  log "Disabling swap (kubelet requirement)"
  swapoff -a
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

  log "Loading kernel modules + sysctls"
  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay; modprobe br_netfilter
  cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  log "Installing containerd"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg nfs-common >/dev/null
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  fi
  systemctl restart containerd && systemctl enable containerd >/dev/null

  log "Installing kubeadm/kubelet/kubectl ($K8S_MINOR)"
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
  apt-mark hold kubelet kubeadm kubectl >/dev/null
  systemctl enable --now kubelet >/dev/null
  log "Node prepared: $(hostname)"
}

cmd_controlplane() {
  local cp_ip="${CP_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}"
  log "kubeadm init on $cp_ip (pod CIDR $POD_CIDR)"
  kubeadm init --apiserver-advertise-address="$cp_ip" --pod-network-cidr="$POD_CIDR"

  local user="${SUDO_USER:-root}" home
  home=$(getent passwd "$user" | cut -d: -f6)
  mkdir -p "$home/.kube"
  cp -f /etc/kubernetes/admin.conf "$home/.kube/config"
  chown "$(id -u "$user"):$(id -g "$user")" "$home/.kube/config"

  log "Installing Flannel CNI"
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f \
    https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  echo
  log "Run this on EACH worker (with sudo):"
  kubeadm token create --print-join-command
}

case "${1:-}" in
  common)       cmd_common ;;
  controlplane) cmd_controlplane ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
