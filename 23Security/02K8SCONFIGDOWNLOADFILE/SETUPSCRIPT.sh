#!/bin/bash

# ================================================================
# Kubernetes Remote Access Fix Script
# ================================================================
#
# PURPOSE:
# This script updates the Kubernetes API Server certificate so that
# the API Server can be accessed using the Azure VM's PUBLIC IP.
#
# WHY IS THIS REQUIRED?
#
# Kubernetes API Server uses TLS certificates.
# The certificate contains a list of valid addresses called
# Subject Alternative Names (SANs).
#
# Example:
#
#   Kubernetes API Server certificate
#           |
#           +---- PRIVATE IP
#           |
#           +---- PUBLIC IP
#           |
#           +---- 127.0.0.1
#
# If your kubeconfig connects to:
#
#       https://PUBLIC-IP:6443
#
# but PUBLIC-IP is NOT present in the API Server certificate SANs,
# TLS verification will fail with an error similar to:
#
#   x509: certificate is valid for <PRIVATE-IP>, not <PUBLIC-IP>
#
# This script:
#
#   1. Asks for the Azure VM Public IP
#   2. Detects the VM's Private IP
#   3. Creates a kubeadm configuration
#   4. Backs up the existing API Server certificate
#   5. Removes the old API Server certificate
#   6. Regenerates the certificate with the Public + Private IP
#   7. Restarts kubelet
#   8. Creates a kubeconfig for remote/laptop access
#   9. Verifies the new certificate SANs
#  10. Checks Kubernetes cluster health
#
# IMPORTANT:
# Run this script on the Kubernetes CONTROL-PLANE node as root.
#
# ================================================================

# Exit immediately if any command fails.
#
# Without this, the script could continue after an important
# command failed and leave the Kubernetes control plane in a
# partially modified state.
set -e


echo "================================================"
echo " Kubernetes Remote Access Fix Script"
echo "================================================"
echo ""

# ----------------------------------------------------------------
# STEP 0: Ask for the Azure VM Public IP
# ----------------------------------------------------------------
#
# The Public IP is the address that your laptop will use to reach
# the Kubernetes API Server.
#
# Example:
#
#   Public IP: 20.10.30.40
#
# Your laptop will eventually connect to:
#
#   https://20.10.30.40:6443
#
# ----------------------------------------------------------------

read -p "Enter Azure VM Public IP: " PUBLIC_IP


# ----------------------------------------------------------------
# Detect the VM's Private IP
# ----------------------------------------------------------------
#
# hostname -I displays the IP addresses assigned to the machine.
#
# awk '{print $1}' takes the first address.
#
# Example:
#
#   hostname -I
#
# might return:
#
#   10.0.1.4 172.17.0.1
#
# We use:
#
#   10.0.1.4
#
# as the Kubernetes control-plane private IP.
#
# ----------------------------------------------------------------

PRIVATE_IP=$(hostname -I | awk '{print $1}')


echo ""
echo "Detected Private IP : $PRIVATE_IP"
echo "Entered Public IP   : $PUBLIC_IP"
echo ""


# ----------------------------------------------------------------
# Create a backup directory
# ----------------------------------------------------------------
#
# Before changing certificates, we create a backup location.
#
# If something goes wrong, the original certificate files are
# available under:
#
#   /root/k8s-backup/
#
# mkdir -p means:
#
#   - Create the directory if it does not exist
#   - Do not complain if it already exists
#
# ----------------------------------------------------------------

mkdir -p /root/k8s-backup


# ================================================================
# [1/8] Create kubeadm configuration
# ================================================================

echo "[1/8] Creating kubeadm configuration..."


# ----------------------------------------------------------------
# Create a kubeadm configuration file.
#
# kubeadm will use this configuration when generating the new
# API Server certificate.
#
# certSANs = Certificate Subject Alternative Names
#
# We explicitly add:
#
#   1. Azure Public IP
#      -> Allows remote/laptop access using the Public IP
#
#   2. Private IP
#      -> Keeps existing internal/control-plane access working
#
#   3. 127.0.0.1
#      -> Allows local access through localhost
#
# ----------------------------------------------------------------

cat > /root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration

apiServer:
  certSANs:
  - "${PUBLIC_IP}"
  - "${PRIVATE_IP}"
  - "127.0.0.1"
EOF


echo ""
echo "Generated kubeadm configuration:"
echo "---------------------------------"
cat /root/kubeadm-config.yaml
echo ""


# ================================================================
# [2/8] Backup existing certificates
# ================================================================

echo "[2/8] Backing up existing certificates..."


# ----------------------------------------------------------------
# Kubernetes stores the API Server certificate here:
#
#   /etc/kubernetes/pki/apiserver.crt
#
# And the corresponding private key here:
#
#   /etc/kubernetes/pki/apiserver.key
#
# We make timestamped backups before deleting/recreating them.
#
# Example:
#
#   apiserver.crt.bak.2026-09-11-090000
#
# The timestamp prevents a previous backup from being overwritten.
# ----------------------------------------------------------------

BACKUP_TIMESTAMP=$(date +%F-%H%M%S)


# Backup API Server certificate if it exists.

if [ -f /etc/kubernetes/pki/apiserver.crt ]; then

    cp /etc/kubernetes/pki/apiserver.crt \
       "/root/k8s-backup/apiserver.crt.bak.${BACKUP_TIMESTAMP}"

    echo "Backed up apiserver.crt"

fi


# Backup API Server private key if it exists.

if [ -f /etc/kubernetes/pki/apiserver.key ]; then

    cp /etc/kubernetes/pki/apiserver.key \
       "/root/k8s-backup/apiserver.key.bak.${BACKUP_TIMESTAMP}"

    echo "Backed up apiserver.key"

fi


echo "Certificate backup completed."
echo ""


# ================================================================
# [3/8] Remove old API Server certificate
# ================================================================

echo "[3/8] Removing old API Server certificate..."


# ----------------------------------------------------------------
# kubeadm has a useful behavior:
#
# If the API Server certificate already exists, kubeadm normally
# does NOT regenerate it.
#
# Therefore, we remove the old certificate and key.
#
# This forces:
#
#   kubeadm init phase certs apiserver
#
# to generate a fresh certificate using our new certSANs.
#
# IMPORTANT:
#
# We backed up the files in STEP 2 before removing them.
# ----------------------------------------------------------------

rm -f /etc/kubernetes/pki/apiserver.crt
rm -f /etc/kubernetes/pki/apiserver.key


echo "Old API Server certificate removed."
echo ""


# ================================================================
# [4/8] Generate new API Server certificate
# ================================================================

echo "[4/8] Generating new API Server certificate..."


# ----------------------------------------------------------------
# Generate ONLY the API Server certificate.
#
# We are not reinitializing the Kubernetes cluster.
#
# We are NOT running:
#
#   kubeadm reset
#   kubeadm init
#
# Instead, we are running the specific kubeadm certificate phase:
#
#   kubeadm init phase certs apiserver
#
# kubeadm reads:
#
#   /root/kubeadm-config.yaml
#
# and creates a new:
#
#   /etc/kubernetes/pki/apiserver.crt
#   /etc/kubernetes/pki/apiserver.key
#
# with the configured SANs.
# ----------------------------------------------------------------

kubeadm init phase certs apiserver \
    --config /root/kubeadm-config.yaml


echo ""
echo "New API Server certificate generated."
echo ""


# ================================================================
# [5/8] Restart kubelet
# ================================================================

echo "[5/8] Restarting kubelet..."


# ----------------------------------------------------------------
# kubelet manages the Kubernetes control-plane static pods.
#
# The API Server is normally running as a static pod.
#
# Restarting kubelet makes it notice the changed certificate and
# ensures the API Server is recreated/restarted with the new
# certificate.
#
# ----------------------------------------------------------------

systemctl restart kubelet


echo "Kubelet restarted."
echo ""
echo "Waiting for the control plane to restart..."


# Give the API Server time to come back up.

sleep 30


# ================================================================
# [6/8] Verify certificate SAN entries
# ================================================================

echo "[6/8] Verifying SAN entries..."


# ----------------------------------------------------------------
# openssl x509 reads the generated certificate.
#
# -in
#     Certificate file to inspect
#
# -text
#     Display certificate details in human-readable form
#
# -noout
#     Do not output the encoded certificate itself
#
# We then search for:
#
#   Subject Alternative Name
#
# This should show something similar to:
#
#   X509v3 Subject Alternative Name:
#       IP Address:20.x.x.x,
#       IP Address:10.x.x.x,
#       IP Address:127.0.0.1
#
# The important part is that the Azure PUBLIC IP appears here.
# ----------------------------------------------------------------

openssl x509 \
    -in /etc/kubernetes/pki/apiserver.crt \
    -text \
    -noout | grep -A2 "Subject Alternative Name"


echo ""


# ================================================================
# [7/8] Create kubeconfig for laptop
# ================================================================

echo "[7/8] Creating kubeconfig for laptop..."


# ----------------------------------------------------------------
# /etc/kubernetes/admin.conf is the administrator kubeconfig
# generated by kubeadm.
#
# It contains:
#
#   - Kubernetes API Server address
#   - CA certificate
#   - Client certificate
#   - Client private key
#   - Authentication information
#
# We copy it to the azure user's home directory so that it can
# later be downloaded to the administrator's laptop.
# ----------------------------------------------------------------

cp /etc/kubernetes/admin.conf /home/azure/admin.conf


# ----------------------------------------------------------------
# IMPORTANT:
#
# The original admin.conf normally points to the Kubernetes
# control-plane PRIVATE IP:
#
#   https://10.x.x.x:6443
#
# That address works from inside the Azure VNet but normally
# cannot be reached directly from your laptop over the Internet.
#
# We therefore replace:
#
#   PRIVATE_IP:6443
#
# with:
#
#   PUBLIC_IP:6443
#
# Result:
#
#   https://PUBLIC_IP:6443
#
# Now the laptop's kubectl knows to connect through the Azure
# Public IP.
# ----------------------------------------------------------------

sed -i \
    "s#https://${PRIVATE_IP}:6443#https://${PUBLIC_IP}:6443#g" \
    /home/azure/admin.conf


# ----------------------------------------------------------------
# The kubeconfig contains credentials.
#
# Make sure the azure user owns the file.
# ----------------------------------------------------------------

chown azure:azure /home/azure/admin.conf


# ----------------------------------------------------------------
# chmod 600 means:
#
#   Owner      -> read + write
#   Group      -> no access
#   Others     -> no access
#
# This protects the Kubernetes administrator credentials.
# ----------------------------------------------------------------

chmod 600 /home/azure/admin.conf


echo "Laptop kubeconfig created:"
echo "/home/azure/admin.conf"
echo ""


# ================================================================
# [8/8] Cluster Health Check
# ================================================================

echo "[8/8] Cluster Health Check"


# ----------------------------------------------------------------
# Tell kubectl to use the control-plane's local admin kubeconfig.
#
# We deliberately use:
#
#   /etc/kubernetes/admin.conf
#
# here instead of the modified laptop copy.
#
# This means our local health check is performed directly against
# the control plane.
# ----------------------------------------------------------------

export KUBECONFIG=/etc/kubernetes/admin.conf


echo ""
echo "Checking Kubernetes nodes..."
echo "----------------------------"

kubectl get nodes


echo ""
echo "Checking all Kubernetes pods..."
echo "------------------------------"

kubectl get pods -A


echo ""


# ================================================================
# SUCCESS
# ================================================================

echo "================================================"
echo " SUCCESS"
echo "================================================"
echo ""


# ----------------------------------------------------------------
# Tell the administrator where the generated kubeconfig is.
# ----------------------------------------------------------------

echo "Laptop kubeconfig:"
echo "/home/azure/admin.conf"
echo ""


# ----------------------------------------------------------------
# Example command to download the kubeconfig.
#
# Run this command FROM YOUR LAPTOP, not from the VM.
#
# It copies:
#
#   Azure VM
#       |
#       | SCP
#       v
#   Laptop
#
# The downloaded file is renamed to:
#
#   cluster1.yaml
# ----------------------------------------------------------------

echo "From your laptop:"
echo "scp azure@${PUBLIC_IP}:/home/azure/admin.conf ./cluster1.yaml"
echo ""


# ----------------------------------------------------------------
# After downloading, use:
#
#   kubectl --kubeconfig ./cluster1.yaml get nodes
#
# to test remote access.
# ----------------------------------------------------------------

echo "Then test from your laptop:"
echo "kubectl --kubeconfig ./cluster1.yaml get nodes"
echo ""


echo "Remote Kubernetes access configuration completed."
echo ""
