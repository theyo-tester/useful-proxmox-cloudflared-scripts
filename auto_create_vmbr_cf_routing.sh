#!/usr/bin/env bash
# ==============================================================================
# Script: auto_create_vmbr_cf_routing.sh
# Purpose: Creates an isolated, persistent PVE Linux bridge and attaches a
#          veth interface to an LXC container. Restart is optional and detached.
# ==============================================================================

set -uo pipefail

INTERFACES_FILE="/etc/network/interfaces"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root on your Proxmox VE host."
  exit 1
fi

echo "=========================================="
echo " Proxmox Isolated Bridge & LXC Setup Script"
echo "=========================================="

# Returns 0 if the bridge is defined (auto/iface line) in the interfaces file
bridge_defined() {
  grep -qE "^[[:space:]]*(auto|iface)[[:space:]]+${1}([[:space:]]|$)" "$INTERFACES_FILE" 2>/dev/null
}

# Returns 0 if the bridge exists either live or in the config
bridge_exists() {
  ip link show "$1" >/dev/null 2>&1 || bridge_defined "$1"
}

# ------------------------------------------------------------------------------
# 1. Determine Bridge Name
# ------------------------------------------------------------------------------
DEFAULT_BRIDGE="vmbr1"
BRIDGE_NUM=1

while bridge_exists "$DEFAULT_BRIDGE"; do
  ((BRIDGE_NUM++))
  DEFAULT_BRIDGE="vmbr${BRIDGE_NUM}"
done

read -rp "[?] Enter Linux Bridge name [Default: ${DEFAULT_BRIDGE}]: " USER_BRIDGE
BRIDGE_NAME="${USER_BRIDGE:-$DEFAULT_BRIDGE}"

if bridge_exists "$BRIDGE_NAME"; then
  echo "[-] Error: Bridge ${BRIDGE_NAME} is already in use on this system!"
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Determine Bridge IP / Subnet Safety Check
# ------------------------------------------------------------------------------
SUGGESTED_PVE_IP="10.20.30.2"

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
  echo "[+] Suggested non-conflicting IP: ${SUGGESTED_PVE_IP}"
fi

read -rp "[?] Enter Proxmox Host Bridge IP (CIDR /24) [Default: ${SUGGESTED_PVE_IP}/24]: " USER_PVE_IP
PVE_BRIDGE_IP="${USER_PVE_IP:-${SUGGESTED_PVE_IP}/24}"

IP_ONLY=$(echo "$PVE_BRIDGE_IP" | cut -d'/' -f1)
BASE_OCTETS=$(echo "$IP_ONLY" | cut -d. -f1-3)
SUGGESTED_LXC_IP="${BASE_OCTETS}.3"

# ------------------------------------------------------------------------------
# 3. Locate Target LXC Container
# ------------------------------------------------------------------------------
echo ""
echo "[*] Searching for 'cloudflared' container..."

DETECTED_CT_ID=""
if command -v pct >/dev/null 2>&1; then
  DETECTED_CT_ID=$(pct list 2>/dev/null | awk '$3 == "cloudflared" {print $1}' | head -n 1 || true)
fi

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

if ! pct config "$CT_ID" >/dev/null 2>&1; then
  echo "[-] Error: LXC Container ID '$CT_ID' does not exist."
  exit 1
fi

ROOTFS_PATH="/var/lib/lxc/${CT_ID}/rootfs"

# ------------------------------------------------------------------------------
# 4. Determine LXC Interface Name (Starting at eth1)
# ------------------------------------------------------------------------------
CONF_FILE="/etc/pve/lxc/${CT_ID}.conf"

NEXT_NET_INDEX=0
while grep -q "^net${NEXT_NET_INDEX}:" "$CONF_FILE" 2>/dev/null; do
  ((NEXT_NET_INDEX++))
done

ETH_NUM=1
while grep -q "name=eth${ETH_NUM}[, ]" "$CONF_FILE" 2>/dev/null; do
  ((ETH_NUM++))
done
DEFAULT_IF_NAME="eth${ETH_NUM}"

read -rp "[?] Enter interface name inside LXC [Default: ${DEFAULT_IF_NAME}]: " USER_IF_NAME
LXC_IF_NAME="${USER_IF_NAME:-$DEFAULT_IF_NAME}"

# ------------------------------------------------------------------------------
# 5. Determine LXC Container IP
# ------------------------------------------------------------------------------
read -rp "[?] Enter LXC IP for bridge connection [Default: ${SUGGESTED_LXC_IP}/24]: " USER_LXC_IP
LXC_BRIDGE_IP="${USER_LXC_IP:-${SUGGESTED_LXC_IP}/24}"

HOST_PVE_IP="$IP_ONLY"
HOST_ENTRY="${HOST_PVE_IP} px.local"

# ------------------------------------------------------------------------------
# 6. Summary & Confirmation
# ------------------------------------------------------------------------------
echo ""
echo "=== Summary of Changes ==="
echo " Bridge Name:    ${BRIDGE_NAME} (Isolated, persistent)"
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
BACKUP_FILE="${INTERFACES_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
echo "[*] Backing up ${INTERFACES_FILE} to ${BACKUP_FILE}..."
if ! cp -a "$INTERFACES_FILE" "$BACKUP_FILE"; then
  echo "[-] Error: Backup failed. Aborting, nothing was changed."
  exit 1
fi

echo "[*] Adding bridge ${BRIDGE_NAME} to ${INTERFACES_FILE}..."
cat <<EOF >> "$INTERFACES_FILE"

# Isolated bridge for LXC host communication
auto ${BRIDGE_NAME}
iface ${BRIDGE_NAME} inet static
	address ${PVE_BRIDGE_IP}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF

echo "[*] Bringing up network interface ${BRIDGE_NAME}..."
if ! ifup "$BRIDGE_NAME"; then
  echo "[-] Error: 'ifup ${BRIDGE_NAME}' failed. The LXC config was NOT changed."
  echo "    Check:  journalctl -b -u networking"
  echo "    Backup: ${BACKUP_FILE}"
  exit 1
fi

if ! ip -br addr show "$BRIDGE_NAME" | grep -q "$IP_ONLY"; then
  echo "[-] Error: ${BRIDGE_NAME} is up but does not have ${IP_ONLY}. The LXC config was NOT changed."
  exit 1
fi
echo "[+] ${BRIDGE_NAME} is up with ${PVE_BRIDGE_IP}"

# ------------------------------------------------------------------------------
# 8. Attach Network Interface to LXC Config
# ------------------------------------------------------------------------------
NET_SLOT="net${NEXT_NET_INDEX}"
echo "[*] Adding ${NET_SLOT} (${LXC_IF_NAME}) to LXC ${CT_ID} config..."

if ! pct set "$CT_ID" -"${NET_SLOT}" "name=${LXC_IF_NAME},bridge=${BRIDGE_NAME},ip=${LXC_BRIDGE_IP},type=veth"; then
  echo "[-] Error: 'pct set' failed. The bridge is configured, but the LXC config was not changed."
  exit 1
fi

CT_RUNNING=false
if pct status "$CT_ID" | grep -q "status: running"; then
  CT_RUNNING=true
fi

# Schedules stop -> hosts edit -> start as a systemd unit, detached from this shell
schedule_restart() {
  local unit="ct-${CT_ID}-setup-$(date +%H%M%S)"
  local job="pct stop ${CT_ID}; if pct mount ${CT_ID} >/dev/null 2>&1; then sed -i '/px\\.local/d' ${ROOTFS_PATH}/etc/hosts && echo '${HOST_ENTRY}' >> ${ROOTFS_PATH}/etc/hosts; pct unmount ${CT_ID} >/dev/null 2>&1; fi; pct start ${CT_ID}"

  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "[-] systemd-run not found; cannot schedule a detached restart."
    return 1
  fi

  systemd-run --unit="$unit" --collect --on-active=10s \
    --description="Restart LXC ${CT_ID} after bridge setup" \
    /bin/bash -c "$job" || return 1

  echo "[+] Restart scheduled in ~10 seconds as unit: ${unit}"
  echo "    Follow it with: journalctl -u ${unit}"
  return 0
}

RESTART_SCHEDULED=false
if [ "$CT_RUNNING" = true ]; then
  echo ""
  echo "[!] Container ${CT_ID} is running. ${LXC_IF_NAME} appears only after a restart."
  echo "    A restart drops any connection that goes through this container (e.g. the tunnel)."
  echo "    Recommended: restart later, from the Proxmox web UI console."
  read -rp "[?] Schedule a detached restart of CT ${CT_ID} now? [y/N]: " RESTART
  if [[ "$RESTART" =~ ^[Yy]$ ]]; then
    if schedule_restart; then
      RESTART_SCHEDULED=true
    else
      echo "[!] Restart not scheduled. Restart manually: pct stop ${CT_ID} && pct start ${CT_ID}"
    fi
  else
    echo "[i] No restart. Apply later with: pct stop ${CT_ID} && pct start ${CT_ID}"
  fi
fi

# ------------------------------------------------------------------------------
# 9. Write Host Resolution to /etc/hosts Inside Container
# ------------------------------------------------------------------------------
HOSTS_CMD="sed -i '/px\\.local/d' /etc/hosts && echo '${HOST_ENTRY}' >> /etc/hosts"
echo "[*] Setting /etc/hosts entry in LXC ${CT_ID}..."

if [ "$RESTART_SCHEDULED" = true ]; then
  echo "[i] /etc/hosts is updated by the restart job (stop, edit, start)."
elif [ "$CT_RUNNING" = true ]; then
  if pct exec "$CT_ID" -- sh -c "$HOSTS_CMD"; then
    echo "[+] /etc/hosts updated in running container."
  else
    echo "[!] Warning: could not update /etc/hosts in running container."
  fi
else
  if pct mount "$CT_ID" >/dev/null 2>&1; then
    sed -i '/px\.local/d' "${ROOTFS_PATH}/etc/hosts" && echo "${HOST_ENTRY}" >> "${ROOTFS_PATH}/etc/hosts"
    pct unmount "$CT_ID" >/dev/null 2>&1 || true
    echo "[+] /etc/hosts updated in stopped container."
  else
    echo "[!] Warning: could not mount LXC ${CT_ID}; /etc/hosts not updated."
  fi
fi

echo ""
echo "[+] Setup completed."
echo "[i] Check the bridge after a reboot: ip -br addr show ${BRIDGE_NAME}"
if [ "$RESTART_SCHEDULED" = false ] && [ "$CT_RUNNING" = true ]; then
  echo "[i] Once the container restarts, verify: pct exec ${CT_ID} -- ip -br addr show ${LXC_IF_NAME}"
fi
