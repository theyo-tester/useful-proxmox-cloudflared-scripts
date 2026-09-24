#!/bin/bash
set -e

echo "==> Updating packages..."
apt update && apt upgrade -y

echo "==> Installing required packages..."
apt install -y avahi-daemon systemd-resolved

echo "==> Configuring systemd-resolved for mDNS globally..."
# Backup original resolved.conf if not already backed up
if [ ! -f /etc/systemd/resolved.conf.bak ]; then
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
fi

# Ensure MulticastDNS is enabled globally
sed -i '/^#\?MulticastDNS=/cMulticastDNS=yes' /etc/systemd/resolved.conf
if ! grep -q '^MulticastDNS=yes' /etc/systemd/resolved.conf; then
    echo "MulticastDNS=yes" >> /etc/systemd/resolved.conf
fi

echo "==> Configuring global mDNS drop-in override..."
# Drop-ins in /etc/ override vendor defaults in /usr/lib/
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/99-force-mdns.conf << 'EOF'
[Resolve]
MulticastDNS=yes
LLMNR=no
EOF

echo "==> Creating ifupdown sibling hook to override hardcoded mDNS disablements..."
# This script runs alphabetically after the system's default "resolved" script
# to immediately re-enable mDNS when interface settings change.
cat > /etc/network/if-up.d/z-force-mdns << 'EOF'
#!/bin/sh
# Override systemd-resolved's hardcoded mDNS disablement

if [ -n "$IFACE" ] && [ "$IFACE" != "lo" ]; then
    if systemctl --quiet is-active systemd-resolved; then
        resolvectl mdns "$IFACE" yes
    fi
fi
EOF
chmod +x /etc/network/if-up.d/z-force-mdns

echo "==> Enabling and starting services..."
systemctl enable avahi-daemon
systemctl enable systemd-resolved

# Restart services to apply global configuration
systemctl restart systemd-resolved
systemctl restart avahi-daemon

echo "==> Triggering the network hook manually to apply changes immediately..."
IFACE="eth0" /etc/network/if-up.d/z-force-mdns

echo "==> Done! Verifying status..."
# Give it a moment to stabilize
sleep 2
resolvectl status eth0

echo "==> Testing connectivity..."
ping -c 1 google.com || echo "Google ping failed"
ping -c 1 px.local || echo "Local mDNS ping failed"
