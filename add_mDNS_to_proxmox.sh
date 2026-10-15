#!/bin/bash
set -e

echo "==> Updating packages..."
apt update && apt upgrade -y

echo "==> Installing required packages..."
apt install -y avahi-daemon
