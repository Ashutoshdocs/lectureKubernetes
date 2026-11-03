#!/bin/bash
# =====================================================================
# upgrade-helper.sh   (run on MASTER or WORKER as root)
#     sudo bash upgrade-helper.sh
#
# - Detects whether this is the master or a worker
# - Shows current versions (control plane, every node, kubeadm, kubectl)
# - Checks which newer versions exist on pkgs.k8s.io
# - Suggests the next valid version (one minor at a time)
# - Runs 03-upgrade-master.sh / 04-upgrade-worker.sh with the version you pick
# =====================================================================
if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'

minor_of() { echo "$1" | grep -oP 'v?1\.\K[0-9]+' | head -1; }

# Is v1.<minor> published on pkgs.k8s.io?
repo_exists() {
  curl -fsI -o /dev/null --max-time 10 \
    "https://pkgs.k8s.io/core:/stable:/v1.$1/deb/Release.key"
}

available_minors() {   # prints minors after $1 that exist (max 6 ahead)
  local start=$1 m
  for m in $(seq $((start + 1)) $((start + 6))); do
    repo_exists "$m" && echo "$m" || break
  done
}

ask_version() {        # $1 = suggested minor, $2 = list of allowed minors
  local suggested=$1 allowed="$2" choice
  echo "" >&2
  read -rp "Enter version to upgrade to [default 1.${suggested}, q=quit]: " choice
  [ "$choice" = "q" ] && exit 0
  choice=${choice:-1.${suggested}}
  local cm; cm=$(minor_of "$choice")
  if ! echo " $allowed " | grep -q " ${cm} "; then
    echo -e "${R}1.${cm} is not allowed right now. Allowed: $(for a in $allowed; do printf '1.%s ' $a; done)${N}" >&2
    exit 1
  fi
  echo "1.${cm}"
}

# ---------------------------------------------------------------------
# MASTER MODE
# ---------------------------------------------------------------------
master_mode() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  local NODE CP_VER CP_MINOR KADM_VER
  NODE=$(hostname)

  while true; do
    CP_VER=$(kubectl version -o json | tr -d '\n ' | grep -oP '"serverVersion":\{[^}]*"gitVersion":"\K[^"]+')
    CP_MINOR=$(minor_of "$CP_VER")
    KADM_VER=$(kubeadm version -o short 2>/dev/null || echo "not installed")

    echo -e "\n${B}================ CURRENT VERSIONS (master) ================${N}"
    echo -e "Control plane (apiserver) : ${G}${CP_VER}${N}"
    echo -e "kubeadm on this node      : ${KADM_VER}"
    echo -e "kubectl client            : $(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+' | head -1)"
    echo -e "etcd image                : $(grep -oP 'image:\s*\K\S+' /etc/kubernetes/manifests/etcd.yaml)"
    echo ""
    echo "Nodes (kubelet version):"
    kubectl get nodes -o wide

    # workers behind the control plane?
    local BEHIND=""
    while read -r n v; do
      [ "$(minor_of "$v")" -lt "$CP_MINOR" ] && BEHIND="$BEHIND $n"
    done < <(kubectl get nodes --no-headers -o custom-columns=N:.metadata.name,V:.status.nodeInfo.kubeletVersion)

    # kubeadm binary not matching control plane? (e.g. installed a too-new kubeadm)
    local KADM_MINOR; KADM_MINOR=$(minor_of "$KADM_VER")
    if [ -n "$KADM_MINOR" ] && [ "$KADM_MINOR" -gt $((CP_MINOR + 1)) ]; then
      echo -e "\n${Y}NOTE: kubeadm (${KADM_VER}) is more than one minor ahead of the cluster.${N}"
      echo -e "${Y}      The upgrade will put kubeadm back to the right version automatically.${N}"
    fi

    echo -e "\nChecking newer versions on pkgs.k8s.io ..."
    local AVAIL; AVAIL=$(available_minors "$CP_MINOR" | tr '\n' ' ')
    local NEXT=$((CP_MINOR + 1))
    if [ -z "$AVAIL" ]; then
      echo -e "${G}Cluster is on the latest published minor (1.${CP_MINOR}). Nothing to upgrade.${N}"
    else
      echo -e "Newer versions available  : $(for a in $AVAIL; do printf '1.%s ' $a; done)"
      echo -e "Final target possible     : 1.$(echo $AVAIL | awk '{print $NF}')"
      echo -e "Path                      : 1.${CP_MINOR} -> $(for a in $AVAIL; do printf '1.%s -> ' $a; done | sed 's/ -> $//')"
    fi

    echo -e "\n${B}================ SUGGESTION ================${N}"
    if [ -n "$BEHIND" ]; then
      echo -e "${Y}Worker(s)${BEHIND} are behind the control plane (1.${CP_MINOR}).${N}"
      echo -e "${Y}Upgrade them to 1.${CP_MINOR} (option 2) before the next control plane upgrade.${N}"
    elif [ -n "$AVAIL" ]; then
      echo -e "${G}Next step: upgrade control plane 1.${CP_MINOR} -> 1.${NEXT} (option 1)${N}"
    else
      echo -e "${G}All nodes on 1.${CP_MINOR}. Done.${N}"
    fi

    echo -e "\n${B}================ MENU ================${N}"
    echo " 1) Upgrade CONTROL PLANE (this master) to next version"
    echo " 2) Prepare a WORKER upgrade (drain + show command to run on worker)"
    echo " 3) Uncordon a worker (after its upgrade)"
    echo " 4) Refresh versions"
    echo " q) Quit"
    read -rp "Choose: " opt

    case "$opt" in
      1)
        if [ -z "$AVAIL" ]; then echo "Nothing to upgrade."; continue; fi
        if [ -n "$BEHIND" ]; then
          echo -e "${R}Upgrade worker(s)${BEHIND} to 1.${CP_MINOR} first.${N}"
          read -rp "Continue anyway? (y/N): " yn; [ "$yn" = "y" ] || continue
        fi
        echo -e "kubeadm upgrades ONE minor at a time, so the only valid choice is 1.${NEXT}."
        local V; V=$(ask_version "$NEXT" "$NEXT"); [ -z "$V" ] && continue
        read -rp "Upgrade control plane to ${V} now? (y/N): " yn
        [ "$yn" = "y" ] && NEW_VERSION="$V" bash "${SCRIPT_DIR}/03-upgrade-master.sh"
        ;;
      2)
        echo "Workers:"
        kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' \
          -o custom-columns=N:.metadata.name,V:.status.nodeInfo.kubeletVersion
        read -rp "Worker name: " W
        [ -z "$W" ] && continue
        local WV WM; WV=$(kubectl get node "$W" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
        WM=$(minor_of "$WV")
        if [ "$WM" -ge "$CP_MINOR" ]; then
          echo -e "${G}${W} already matches control plane (${WV}). Upgrade the control plane first.${N}"
          continue
        fi
        local WT=$((WM + 1))
        echo -e "${W} is on ${WV}. Next valid version for it: ${G}1.${WT}${N}"
        kubectl drain "$W" --ignore-daemonsets --delete-emptydir-data
        echo -e "\n${Y}Now run this on ${W}:${N}"
        echo -e "   ${G}sudo bash upgrade-helper.sh${N}      (it will suggest 1.${WT})"
        echo -e "   or: ${G}sudo NEW_VERSION=1.${WT} bash 04-upgrade-worker.sh${N}"
        echo -e "Then come back here and choose option 3 to uncordon it."
        read -rp "Press Enter when done..." _
        ;;
      3)
        kubectl get nodes --no-headers -o custom-columns=N:.metadata.name,UNSCHED:.spec.unschedulable,V:.status.nodeInfo.kubeletVersion
        read -rp "Node to uncordon: " W
        [ -n "$W" ] && kubectl uncordon "$W"
        ;;
      4) ;;
      q|Q) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
  done
}

# ---------------------------------------------------------------------
# WORKER MODE
# ---------------------------------------------------------------------
worker_mode() {
  local KUBELET_VER KM CP_VER CP_MINOR
  KUBELET_VER=$(kubelet --version | awk '{print $2}')
  KM=$(minor_of "$KUBELET_VER")
  # kubelet's own credentials can read /version from the apiserver
  CP_VER=$(kubectl --kubeconfig /etc/kubernetes/kubelet.conf version -o json 2>/dev/null \
           | tr -d '\n ' | grep -oP '"serverVersion":\{[^}]*"gitVersion":"\K[^"]+')
  CP_MINOR=$(minor_of "$CP_VER")

  echo -e "\n${B}================ CURRENT VERSIONS (worker) ================${N}"
  echo -e "kubelet on this node      : ${G}${KUBELET_VER}${N}"
  echo -e "kubeadm on this node      : $(kubeadm version -o short 2>/dev/null)"
  echo -e "Control plane (apiserver) : ${CP_VER:-unknown (cannot reach master)}"

  if [ -z "$CP_MINOR" ]; then
    echo -e "${Y}Could not read control plane version. Suggesting 1.$((KM + 1)) (one step).${N}"
    CP_MINOR=$((KM + 1))
  fi

  if [ "$KM" -ge "$CP_MINOR" ]; then
    echo -e "\n${G}This worker already matches the control plane. Upgrade the master first.${N}"
    exit 0
  fi

  local T=$((KM + 1))
  echo -e "\n${B}================ SUGGESTION ================${N}"
  echo -e "Upgrade this worker 1.${KM} -> ${G}1.${T}${N}"
  [ "$T" -lt "$CP_MINOR" ] && echo -e "${Y}(Control plane is on 1.${CP_MINOR}; run this helper again afterwards for the next step.)${N}"
  echo -e "${Y}Make sure the master has drained this node first (helper option 2 on master).${N}"

  local V; V=$(ask_version "$T" "$T"); [ -z "$V" ] && exit 0
  read -rp "Upgrade this worker to ${V} now? (y/N): " yn
  [ "$yn" = "y" ] && NEW_VERSION="$V" bash "${SCRIPT_DIR}/04-upgrade-worker.sh"
}

# ---------------------------------------------------------------------
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
  master_mode
elif [ -f /etc/kubernetes/kubelet.conf ]; then
  worker_mode
else
  echo "This node is not part of a kubeadm cluster yet. Run ScriptForBothNode.sh first."
  exit 1
fi
