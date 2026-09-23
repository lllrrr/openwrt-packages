#!/bin/sh
# Test suite for UPS Manager
# Validates syntax, RPC interfaces, and parsing

set -e

echo "=== 1. Validating Shell Scripts Syntax ==="
for f in root/usr/libexec/rpcd/luci.ups-manager root/usr/bin/ups-manager-daemon root/usr/bin/ups-manager-notify root/usr/bin/ups-manager-shutdown root/etc/init.d/ups-manager; do
    echo -n "Checking $f ... "
    sh -n "$f"
    echo "OK"
done

echo ""
echo "=== 2. Testing RPC list interface ==="
root/usr/libexec/rpcd/luci.ups-manager list

echo ""
echo "=== 3. Testing RPC call scan_devices ==="
root/usr/libexec/rpcd/luci.ups-manager call scan_devices
echo ""

echo ""
echo "=== 4. Testing RPC call diagnose ==="
root/usr/libexec/rpcd/luci.ups-manager call diagnose
echo ""

echo ""
echo "=== All syntax and base RPC checks passed successfully! ==="
