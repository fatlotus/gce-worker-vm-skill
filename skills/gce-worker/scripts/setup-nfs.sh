#!/usr/bin/env bash
# setup-nfs.sh - Configure and start NFS server restricted strictly to 10.0.0.0/8
set -euo pipefail

EXPORT_DIR="${1:-$HOME}"
ALLOWED_NETWORK="10.0.0.0/8"

echo "=== Setting up NFS Server for ${EXPORT_DIR} restricted to ${ALLOWED_NETWORK} ==="

# 1. Install nfs-kernel-server if not present
if ! command -v exportfs >/dev/null 2>&1; then
  echo "Installing nfs-kernel-server..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server rpcbind
fi

# 2. Configure exports restricted strictly to 10.0.0.0/8
sudo mkdir -p /etc/exports.d
EXPORTS_FILE="/etc/exports.d/agy-home.exports"
DESIRED_EXPORT="${EXPORT_DIR} ${ALLOWED_NETWORK}(rw,sync,no_subtree_check,no_root_squash)"

echo "Writing export rule to ${EXPORTS_FILE}:"
echo "  ${DESIRED_EXPORT}"

echo "${DESIRED_EXPORT}" | sudo tee "${EXPORTS_FILE}" >/dev/null

# 3. Reload exports and ensure service is active
echo "Applying exports..."
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server rpcbind
sudo systemctl restart nfs-kernel-server

# 4. Enforce strict firewall restriction for NFS/RPC ports (111 and 2049)
# Explicitly ALLOW 10.0.0.0/8 and 127.0.0.1, and explicitly DROP any other sources
for port in 111 2049; do
  for proto in tcp udp; do
    # Allow 10.0.0.0/8
    if ! sudo iptables -C INPUT -p "${proto}" --dport "${port}" -s 10.0.0.0/8 -j ACCEPT 2>/dev/null; then
      sudo iptables -I INPUT 1 -p "${proto}" --dport "${port}" -s 10.0.0.0/8 -j ACCEPT
    fi
    # Allow local loopback
    if ! sudo iptables -C INPUT -p "${proto}" --dport "${port}" -s 127.0.0.1 -j ACCEPT 2>/dev/null; then
      sudo iptables -I INPUT 2 -p "${proto}" --dport "${port}" -s 127.0.0.1 -j ACCEPT
    fi
    # Drop all other incoming traffic on these ports
    if ! sudo iptables -C INPUT -p "${proto}" --dport "${port}" ! -s 10.0.0.0/8 ! -s 127.0.0.1 -j DROP 2>/dev/null; then
      sudo iptables -A INPUT -p "${proto}" --dport "${port}" ! -s 10.0.0.0/8 ! -s 127.0.0.1 -j DROP
    fi
  done
done

# 5. Detect local IP in 10.0.0.0/8
LOCAL_IP=$(ip -4 -o addr show to 10.0.0.0/8 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
if [ -z "${LOCAL_IP}" ]; then
  LOCAL_IP=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip || true)
fi

echo "=== NFS Server Status ==="
sudo exportfs -v
echo "Local private NFS IP: ${LOCAL_IP}"
echo "NFS setup complete and secured."
