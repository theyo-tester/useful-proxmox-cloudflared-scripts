#!/usr/bin/env bash
# ==============================================================================
# Script: setup_pve_isolated_bridge.sh
# Purpose: Creates an isolated PVE Linux Bridge and attaches an interface to an LXC
# ==============================================================================

set -euo pipefail

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root on your Proxmox VE host."
  exit 1
fi

echo "=========================================="
echo " Proxmox Isolated Bridge & LXC Setup Script"
echo "=========================================="

# ------------------------------------------------------------------------------
# 1. Determine Bridge Name
# ------------------------------------------------------------------------------
DEFAULT_BRIDGE="vmbr1"
BRIDGE_NUM=1

while ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1 || grep -q "iface $DEFAULT_BRIDGE" /etc/network/interfaces 2>/dev/null; do
  ((BRIDGE_NUM++))
  DEFAULT_BRIDGE="vmbr${BRIDGE_NUM}"
done

read -rp "[?] Enter Linux Bridge name [Default: ${DEFAULT_BRIDGE}]: " USER_BRIDGE
BRIDGE_NAME="${USER_BRIDGE:-$DEFAULT_BRIDGE}"

if ip link show "$BRIDGE_NAME" >/dev/null 2>&1 || grep -q "iface $BRIDGE_NAME" /etc/network/interfaces 2>/dev/null; do
  echo "[-] Error: Bridge ${BRIDGE_NAME} is already in use on this system!"
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Determine Bridge IP / Subnet Safety Check
# ------------------------------------------------------------------------------
SUGGESTED_PVE_IP="10.20.30.2"
BASE_OCTETS="10.20.30"

check_ip_conflict() {
  local test_ip="$1"
  local subnet
  subnet=$(echo "$test_ip" | cut -d. -f1-3)
  
  if ip addr show | grep -q "$test_ip" || ip route show | grep -q "${subnet}\."; then
    return 0 # Conflict found
  fi
  return 1 # Safe
}

if check_ip_conflict "$SUGGESTED_PVE_IP"; then
  echo "[!] Notice: $SUGGESTED_PVE_IP or its subnet is currently in use."
  COUNTER=31
  while check_ip_conflict "10.20.${COUNTER}.2"; do
    ((COUNTER++))
  done
  SUGGESTED_PVE_IP="10.20.${COUNTER}.2"
  BASE_OCTETS="10.20.${COUNTER}"
  echo "[+] Suggested non-conflicting IP: ${SUGGESTED_PVE_IP}"
fi

read -rp "[?] Enter Proxmox Host Bridge IP (CIDR /24) [Default: ${SUGGESTED_PVE_IP}/24]: " USER_PVE_IP
PVE_BRIDGE_IP="${USER_PVE_IP:-${SUGGESTED_PVE_IP}/24}"

# Extract base octets in case user entered a custom IP
IFS='/' read -r IP_ONLY CIDR <<< "$PVE_BRIDGE_IP"
BASE_OCTETS=$(echo "$IP_ONLY" | cut -d. -f1-3)
SUGGESTED_LXC_IP="${BASE_OCTETS}.3"

# ------------------------------------------------------------------------------
# 3. Locate Target LXC Container
# ------------------------------------------------------------------------------
echo ""
echo "[*] Searching for 'cloudflared' container..."
DETECTED_CT_ID=$(pct list | awk -v name="cloudflared" '$3 == name {print $1}')

if [ -n "$DETECTED_CT_ID" ]; then
  echo "[+] Found container 'cloudflared' with ID: ${DETECTED_CT_ID}"
  SUGGESTED_CT_ID="$DETECTED_CT_ID"
else
  echo "[!] Container named 'cloudflared' not found."
  SUGGESTED_CT_ID=""
fi

read -rp "[?] Enter target LXC Container ID [Default: ${SUGGESTED_CT_ID}]: " USER_CT_ID
CT_ID="${USER_CT_ID:-$SUGGESTED_CT_ID}"

if [ -z "$CT_ID" ]; then
  echo "[-] Error: No Container ID specified."
  exit 1
fi

if ! pct status "$CT_ID" >/dev/null 2>&1; then
  echo "[-] Error: LXC Container ID $CT_ID does not exist."
  exit 1
fi

# ------------------------------------------------------------------------------
# 4. Determine LXC Container IP
# ------------------------------------------------------------------------------
read -rp "[?] Enter LXC IP for bridge connection [Default: ${SUGGESTED_LXC_IP}/24]: " USER_LXC_IP
LXC_BRIDGE_IP="${USER_LXC_IP:-${SUGGESTED_LXC_IP}/24}"

# Parse clean host IP without subnet mask for hosts entry
IFS='/' read -r HOST_PVE_IP _ <<< "$PVE_BRIDGE_IP"

# ------------------------------------------------------------------------------
# 5. Summary & Confirmation
# ------------------------------------------------------------------------------
echo ""
echo "=== Summary of Changes ==="
echo " Bridge Name:    ${BRIDGE_NAME} (Isolated, no physical nic)"
echo " Host Bridge IP: ${PVE_BRIDGE_IP}"
echo " LXC ID:         ${CT_ID}"
echo " LXC IP:         ${LXC_BRIDGE_IP}"
echo " /etc/hosts:     ${HOST_PVE_IP} px.local (inside LXC ${CT_ID})"
echo "=========================="
read -rp "Proceed with configuration? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[-] Aborted by user."
  exit 0
fi

# ------------------------------------------------------------------------------
# 6. Apply Network Configuration to Proxmox
# ------------------------------------------------------------------------------
echo "[*] Adding bridge ${BRIDGE_NAME} to /etc/network/interfaces..."

cat <<EOF >> /etc/network/interfaces

iface ${BRIDGE_NAME} inet static
	address ${PVE_BRIDGE_IP}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
# Isolated bridge for LXC host communication
EOF

echo "[*] Bringing up network interface ${BRIDGE_NAME}..."
ifup "${BRIDGE_NAME}" || ip link set "${BRIDGE_NAME}" up

# ------------------------------------------------------------------------------
# 7. Attach Network Interface to LXC Container
# ------------------------------------------------------------------------------
# Find next available net index (net0, net1, etc.)
NEXT_NET_INDEX=0
while grep -q "^net${NEXT_NET_INDEX}:" "/etc/pve/lxc/${CT_ID}.conf" 2>/dev/null; do
  ((NEXT_NET_INDEX++))
done

NET_IF_NAME="net${NEXT_NET_INDEX}"
echo "[*] Assigning ${BRIDGE_NAME} to LXC ${CT_ID} as interface ${NET_IF_NAME}..."

pct set "$CT_ID" -"${NET_IF_NAME}" "name=eth${NEXT_NET_INDEX},bridge=${BRIDGE_NAME},ip=${LXC_BRIDGE_IP},type=veth"

# ------------------------------------------------------------------------------
# 8. Add Entry to /etc/hosts inside the Container
# ------------------------------------------------------------------------------
HOST_ENTRY="${HOST_PVE_IP} px.local"
echo "[*] Updating /etc/hosts in LXC ${CT_ID}..."

if pct status "$CT_ID" | grep -q "running"; then
  pct exec "$CT_ID" -- bash -c "grep -q 'px.local' /etc/hosts && sed -i 's/.*px.local.*/${HOST_ENTRY}/' /etc/hosts || echo '${HOST_ENTRY}' >> /etc/hosts"
else
  # Container stopped: edit rootfs directory directly
  ROOTFS_PATH="/var/lib/lxc/${CT_ID}/rootfs"
  if [ -f "${ROOTFS_PATH}/etc/hosts" ]; then
    if grep -q 'px.local' "${ROOTFS_PATH}/etc/hosts"; then
      sed -i "s/.*px.local.*/${HOST_ENTRY}/" "${ROOTFS_PATH}/etc/hosts"
    else
      echo "${HOST_ENTRY}" >> "${ROOTFS_PATH}/etc/hosts"
    fi
  else
    echo "[!] Warning: Container host file not directly accessible. Start the container and manually add '${HOST_ENTRY}' to /etc/hosts."
  fi
fi

echo "[+] Setup successfully completed!"
