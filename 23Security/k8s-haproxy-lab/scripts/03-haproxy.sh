#!/usr/bin/env bash
###############################################################################
# 03-haproxy.sh   -- run on haproxy-vm
#
# Installs HAProxy and drops in the config, substituting the two control-plane
# private IPs.
#
# Usage:
#   sudo C1CP_IP=10.0.1.5 C2CP_IP=10.0.1.7 bash 03-haproxy.sh
# (pass the PRIVATE IPs of cluster1-cp and cluster2-cp)
###############################################################################
set -euo pipefail

: "${C1CP_IP:?set C1CP_IP to cluster1-cp private IP}"
: "${C2CP_IP:?set C2CP_IP to cluster2-cp private IP}"

echo ">> Installing HAProxy"
apt-get update -y
apt-get install -y haproxy

echo ">> Writing /etc/haproxy/haproxy.cfg (C1=$C1CP_IP  C2=$C2CP_IP)"
# The template lives next to this script in ../haproxy/haproxy.cfg
CFG_SRC="$(dirname "$0")/../haproxy/haproxy.cfg"
sed -e "s/__C1CP_IP__/${C1CP_IP}/" -e "s/__C2CP_IP__/${C2CP_IP}/" \
    "$CFG_SRC" > /etc/haproxy/haproxy.cfg

echo ">> Validating config"
haproxy -c -f /etc/haproxy/haproxy.cfg

echo ">> Restarting HAProxy"
systemctl restart haproxy
systemctl enable haproxy
systemctl --no-pager status haproxy | head -n 5

echo
echo ">> DONE. Frontends:  :7001 -> $C1CP_IP:6443   :7002 -> $C2CP_IP:6443"
echo ">> Stats: http://<haproxy-public-ip>:8404/stats"
