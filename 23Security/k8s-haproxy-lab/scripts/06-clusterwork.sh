#!/usr/bin/env bash
###############################################################################
# 06-clusterwork.sh   -- run on the clusterwork (bastion) VM
#
# 1. Installs kubectl (the ONLY tool the users need here).
# 2. Creates two Linux logins: manohar and ashutosh (password based) so the
#    two people can SSH into this box and run kubectl.
# 3. Makes sure sshd accepts password logins.
#
# Their kubeconfigs are pushed here later by 07-make-user.sh.
#
# Usage:  sudo bash 06-clusterwork.sh
###############################################################################
set -euo pipefail

K8S_MINOR="v1.33"

echo ">> Install kubectl"
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl

create_login () {
  local user="$1" pass="$2"
  if id "$user" &>/dev/null; then
    echo ">> user $user already exists"
  else
    echo ">> creating login $user"
    useradd -m -s /bin/bash "$user"
  fi
  echo "${user}:${pass}" | chpasswd
  install -d -o "$user" -g "$user" -m 700 "/home/$user/.kube"
}

# CHANGE THESE PASSWORDS
create_login manohar  "Manohar_Pass!2026"
create_login ashutosh "Ashutosh_Pass!2026"

echo ">> Ensure sshd allows password auth"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Azure images sometimes override this in a drop-in file:
if ls /etc/ssh/sshd_config.d/*.conf &>/dev/null; then
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf || true
fi
systemctl restart ssh || systemctl restart sshd

echo
echo ">> DONE. The two people can now SSH in:"
echo "     ssh manohar@<clusterwork-public-ip>    (pw: Manohar_Pass!2026)"
echo "     ssh ashutosh@<clusterwork-public-ip>   (pw: Ashutosh_Pass!2026)"
echo ">> Their kubeconfigs will be delivered by 07-make-user.sh."
