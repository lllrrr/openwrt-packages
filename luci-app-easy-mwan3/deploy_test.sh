#!/bin/bash
# Quick deployment script for Easy MWAN3 testing
# Usage: ./deploy_test.sh <openwrt_ip> [root_password]

set -e

OPENWRT_IP=${1:-""}
ROOT_PASSWORD=${2:-""}

if [ -z "$OPENWRT_IP" ]; then
    echo "Usage: $0 <openwrt_ip> [root_password]"
    echo "Example: $0 192.168.1.1 password"
    exit 1
fi

echo "======================================"
echo "Easy MWAN3 Quick Deployment Script"
echo "======================================"
echo ""

# Test connectivity
echo "[1/6] Testing connectivity to $OPENWRT_IP..."
if ! ping -c 1 -W 2 $OPENWRT_IP >/dev/null 2>&1; then
    echo "ERROR: Cannot reach $OPENWRT_IP"
    exit 1
fi
echo "✓ Host is reachable"

# Check if SSH is available
echo ""
echo "[2/6] Testing SSH connection..."
SSH_CMD=""
if [ -n "$ROOT_PASSWORD" ]; then
    # Use sshpass if available
    if command -v sshpass >/dev/null 2>&1; then
        SSH_CMD="sshpass -p '$ROOT_PASSWORD' ssh -o StrictHostKeyChecking=no root@$OPENWRT_IP"
        SCP_CMD="sshpass -p '$ROOT_PASSWORD' scp -o StrictHostKeyChecking=no"
    else
        echo "WARNING: sshpass not found, will prompt for password"
        SSH_CMD="ssh -o StrictHostKeyChecking=no root@$OPENWRT_IP"
        SCP_CMD="scp -o StrictHostKeyChecking=no"
    fi
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no root@$OPENWRT_IP"
    SCP_CMD="scp -o StrictHostKeyChecking=no"
fi

# Test SSH
if ! $SSH_CMD "echo 'SSH OK'" >/dev/null 2>&1; then
    echo "ERROR: Cannot SSH to $OPENWRT_IP"
    echo "Please check:"
    echo "  1. SSH is enabled on OpenWrt"
    echo "  2. Root password is set"
    echo "  3. Firewall allows SSH"
    exit 1
fi
echo "✓ SSH connection successful"

# Check OpenWrt version
echo ""
echo "[3/6] Checking OpenWrt version..."
OPENWRT_VERSION=$($SSH_CMD "cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION | cut -d= -f2 | tr -d '\"'" || echo "Unknown")
echo "  OpenWrt Version: $OPENWRT_VERSION"

# Check firewall version
echo ""
echo "[4/6] Checking firewall version..."
FW_VERSION=$($SSH_CMD "uci get firewall.@defaults[0].name 2>/dev/null || echo 'unknown'")
echo "  Firewall: $FW_VERSION"
if echo "$FW_VERSION" | grep -q "fw4"; then
    echo ""
    echo "⚠️  WARNING: fw4 detected!"
    echo "   Easy MWAN3 is NOT compatible with fw4"
    echo "   Please use fw3 or install pbr instead"
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check mwan3
echo ""
echo "[5/6] Checking mwan3 installation..."
MWAN3_INSTALLED=$($SSH_CMD "opkg list-installed | grep -q mwan3 && echo 'yes' || echo 'no'")
if [ "$MWAN3_INSTALLED" = "no" ]; then
    echo "  mwan3 NOT installed"
    echo ""
    read -p "Install mwan3 now? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        $SSH_CMD "opkg update && opkg install mwan3"
    fi
else
    echo "  ✓ mwan3 is installed"
fi

# Deploy plugin
echo ""
echo "[6/6] Deploying Easy MWAN3 plugin..."

# Create package directory
echo "  Creating package..."
PACKAGE_DIR=$(mktemp -d)
make DESTDIR="$PACKAGE_DIR" install

# Upload files
echo "  Uploading files..."
$SCP_CMD -r "$PACKAGE_DIR"/* root@$OPENWRT_IP:/

# Run post-install
echo "  Running post-install script..."
$SSH_CMD "chmod +x /usr/bin/easy_mwan3_*.sh && chmod +x /etc/init.d/easy_mwan3 && /etc/uci-defaults/99_easy_mwan3"

# Run test
echo ""
echo "======================================"
echo "Running tests..."
echo "======================================"
$SSH_CMD "/usr/bin/easy_mwan3_test.sh"

echo ""
echo "======================================"
echo "✓ Deployment completed!"
echo "======================================"
echo ""
echo "Access LuCI: http://$OPENWRT_IP/cgi-bin/luci/admin/network/easy_mwan3"
echo ""
echo "Useful commands:"
echo "  Apply config:    /usr/bin/easy_mwan3_apply.sh"
echo "  Check status:    /usr/bin/easy_mwan3_status.sh json"
echo "  Validate config: /usr/bin/easy_mwan3_validate.sh config"
echo "  Run tests:       /usr/bin/easy_mwan3_test.sh"
echo ""

# Cleanup
rm -rf "$PACKAGE_DIR"
