#!/usr/bin/env bash
# ==============================================================================
# Script: auto_create_vmbr_cf_routing.sh
# Purpose: Creates an isolated PVE Linux Bridge and connects an LXC container.
# ==============================================================================

set -euo pipefail

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

if ip link show "$BRIDGE_NAME" >/dev/null 2>&1 || grep -q "iface $BRIDGE_NAME" /etc/network/interfaces 2>/dev/null; then
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
    return 0
  fi
  return 1
}

if check_ip_conflict "$SUGGESTED_PVE_IP"; then
  echo "[!] Notice: $SUGGESTED_PVE_IP or its subnet is in use."
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

IFS='/' read -r IP_ONLY CIDR <<< "$PVE_BRIDGE_IP"
BASE_OCTETS=$(echo "$IP_ONLY" | cut -d. -f1-3)
SUGGESTED_LXC_IP="${BASE_OCTETS}.3"

# ------------------------------------------------------------------------------
# 3. Locate Target LXC Container
# ------------------------------------------------------------------------------
echo ""
echo "[*] Searching for 'cloudflared' container..."
DETECTED_CT_ID=$(pct list 2>/dev/null | awk -v name="cloudflared" '$3 == name {print $1}')

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
# 4. Determine LXC Interface Name (Starting at eth1)
# ------------------------------------------------------------------------------
CONF_FILE="/etc/pve/lxc/${CT_ID}.conf"

# Calculate next net index (net0, net1, net2...)
NEXT_NET_INDEX=0
while grep -q "^net${NEXT_NET_INDEX}:" "$CONF_FILE" 2>/dev/null; do
  ((NEXT_NET_INDEX++))
done

# Calculate next eth device name (starting with eth1, incrementing if used)
ETH_NUM=1
while grep -q "name=eth${ETH_NUM}[, ]" "$CONF_FILE" 2>/dev/null; do
  ((ETH_NUM++))
done
DEFAULT_IF_NAME="eth${ETH_NUM}"

read -rp "[?] Enter interface name for container [Default: ${DEFAULT_IF_NAME}]: " USER_IF_NAME
LXC_IF_NAME="${USER_IF_NAME:-$DEFAULT_IF_NAME}"

# ------------------------------------------------------------------------------
# 5. Determine LXC Container IP
# ------------------------------------------------------------------------------
read -rp "[?] Enter LXC IP for bridge connection [Default: ${SUGGESTED_LXC_IP}/24]: " USER_LXC_IP
LXC_BRIDGE_IP="${USER_LXC_IP:-${SUGGESTED_LXC_IP}/24}"

HOST_PVE_IP="$IP_ONLY"

# ------------------------------------------------------------------------------
# 6. Summary & Confirmation
# ------------------------------------------------------------------------------
echo ""
echo "=== Summary of Changes ==="
echo " Bridge Name:    ${BRIDGE_NAME} (Isolated)"
echo " Host Bridge IP: ${PVE_BRIDGE_IP}"
echo " LXC ID:         ${CT_ID}"
echo " LXC Interface:  ${LXC_IF_NAME} (slot net${NEXT_NET_INDEX})"
echo " LXC IP:         ${LXC_BRIDGE_IP}"
echo " /etc/hosts:     ${HOST_PVE_IP} px.local (inside LXC ${CT_ID})"
echo "=========================="
read -rp "Proceed with configuration? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[-] Aborted by user."
  exit 0
fi

# ------------------------------------------------------------------------------
# 7. Apply Network Configuration to Proxmox Host
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
# 8. Attach Network Interface to LXC Config & Active Namespace
# ------------------------------------------------------------------------------
NET_SLOT="net${NEXT_NET_INDEX}"
echo "[*] Configuring LXC ${CT_ID} with interface ${LXC_IF_NAME} on slot ${NET_SLOT}..."

pct set "$CT_ID" -"${NET_SLOT}" "name=${LXC_IF_NAME},bridge=${BRIDGE_NAME},ip=${LXC_BRIDGE_IP},type=veth"

IS_RUNNING=false
if pct status "$CT_ID" | grep -q "running"; then
  IS_RUNNING=true
fi

if [ "$IS_RUNNING" = true ]; then
  echo "[*] Container is running. Hot-attaching veth device to namespace..."
  
  # Create dynamic veth pair on host and bridge it
  HOST_VETH="veth${CT_ID}i${NEXT_NET_INDEX}"
  GUEST_VETH="veth${CT_ID}g${NEXT_NET_INDEX}"

  ip link add "$HOST_VETH" type veth peer name "$GUEST_VETH" 2>/dev/null || true
  ip link set "$HOST_VETH" master "$BRIDGE_NAME"
  ip link set "$HOST_VETH" up

  # Push guest interface into container namespace
  CT_PID=$(pct status "$CT_ID" -verbose | awk '/pid:/ {print $2}')
  ip link set "$GUEST_VETH" netns "$CT_PID"
  
  # Rename interface and configure IP inside container namespace
  lxc-attach -n "$CT_ID" -- ip link set "$GUEST_VETH" name "$LXC_IF_NAME"
  lxc-attach -n "$CT_ID" -- ip link set "$LXC_IF_NAME" up
  lxc-attach -n "$CT_ID" -- ip addr add "$LXC_BRIDGE_IP" dev "$LXC_IF_NAME"
fi

# ------------------------------------------------------------------------------
# 9. Write Host Resolution to /etc/hosts Inside Container
# ------------------------------------------------------------------------------
HOST_ENTRY="${HOST_PVE_IP} px.local"
echo "[*] Injecting /etc/hosts entry into LXC ${CT_ID}..."

if [ "$IS_RUNNING" = true ]; then
  lxc-attach -n "$CT_ID" -- bash -c "grep -q 'px.local' /etc/hosts && sed -i 's/.*px.local.*/${HOST_ENTRY}/' /etc/hosts || echo '${HOST_ENTRY}' >> /etc/hosts"
else
  # Container stopped: update via temporary pct mount point
  MOUNT_DIR=$(mktemp -d)
  pct mount "$CT_ID" >/dev/null 2>&1 || true
  ROOTFS_PATH="/var/lib/lxc/${CT_ID}/rootfs"
  
  if [ -f "${ROOTFS_PATH}/etc/hosts" ]; then
    if grep -q 'px.local' "${ROOTFS_PATH}/etc/hosts"; then
      sed -i "s/.*px.local.*/${HOST_ENTRY}/" "${ROOTFS_PATH}/etc/hosts"
    else
      echo "${HOST_ENTRY}" >> "${ROOTFS_PATH}/etc/hosts"
    fi
  fi
  pct unmount "$CT_ID" >/dev/null 2>&1 || true
  rm -rf "$MOUNT_DIR"
fi

echo "[+] Setup completed successfully!"
