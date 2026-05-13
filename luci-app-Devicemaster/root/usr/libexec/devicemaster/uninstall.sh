#!/bin/sh
# DeviceMaster Uninstall Cleanup Script
# Removes all residual files, configs, and settings after package removal
# Usage: sh /usr/libexec/devicemaster/uninstall.sh

LOG_TAG="devicemaster-cleanup"

log_msg() {
    logger -t "$LOG_TAG" "$1"
    echo "[cleanup] $1"
}

log_msg "Starting DeviceMaster cleanup..."

# ============================================================
# 1. Stop services
# ============================================================
log_msg "Stopping services..."
/etc/init.d/devicemaster stop 2>/dev/null
/etc/init.d/devicemaster disable 2>/dev/null

# Kill any remaining processes
killall devicemasterd 2>/dev/null
killall device_monitor.sh 2>/dev/null
killall traffic_monitor.sh 2>/dev/null

# ============================================================
# 2. Remove nftables rules
# ============================================================
log_msg "Removing nftables rules..."
nft delete table inet devicemaster 2>/dev/null

# ============================================================
# 3. Remove DHCP event handler reference
# ============================================================
log_msg "Cleaning DHCP dhcpscript..."
CURRENT_SCRIPT=$(uci -q get dhcp.@dnsmasq[0].dhcpscript 2>/dev/null)
if [ "$CURRENT_SCRIPT" = "/usr/libexec/devicemaster/event_handler.sh" ]; then
    uci -q delete dhcp.@dnsmasq[0].dhcpscript
    uci -q commit dhcp
    log_msg "Removed DHCP event handler reference"
fi

# ============================================================
# 4. Remove DHCP host entries created by DeviceMaster
# ============================================================
log_msg "Cleaning DHCP host entries..."
# DeviceMaster entries have names matching device patterns
# Remove all dhcp host entries (they were all created by the plugin)
idx=0
while uci -q get "dhcp.@host[$idx]" >/dev/null 2>&1; do
    uci -q delete "dhcp.@host[$idx]" 2>/dev/null
    # Don't increment idx since delete shifts indices
done
uci -q commit dhcp 2>/dev/null
log_msg "DHCP host entries cleaned"

# Reload dnsmasq to apply changes
/etc/init.d/dnsmasq restart 2>/dev/null

# ============================================================
# 5. Remove UCI configuration
# ============================================================
log_msg "Removing UCI config..."
uci -q batch <<-EOF 2>/dev/null
delete dhcp.devicemaster
commit dhcp
EOF
rm -f /etc/config/devicemaster

# ============================================================
# 6. Remove cron jobs
# ============================================================
log_msg "Removing cron jobs..."
rm -f /etc/cron.d/devicemaster

# ============================================================
# 7. Remove runtime files and caches
# ============================================================
log_msg "Removing runtime files..."
rm -rf /var/run/devicemaster
rm -rf /tmp/devicemaster
rm -f /tmp/devicemaster_device_cache
rm -f /tmp/devicemaster_custom_cache
rm -f /tmp/devicemaster_uci_cache
rm -f /tmp/devicemaster_oui_cache.txt
rm -f /tmp/devicemaster_mdns_cache
rm -f /tmp/devicemaster_nlbwmon_cache
rm -f /tmp/oui_download_result.txt
rm -f /tmp/oui_api_test_result.txt
rm -f /tmp/oui.csv
rm -f /tmp/nlbw_proto_*

# ============================================================
# 8. Remove ACL config
# ============================================================
log_msg "Removing ACL config..."
rm -f /usr/share/rpcd/acl.d/luci-app-devicemaster.json

# ============================================================
# 9. Remove uci-defaults script
# ============================================================
log_msg "Removing uci-defaults script..."
rm -f /etc/uci-defaults/90_devicemaster

# ============================================================
# 10. Remove OUI database and caches
# ============================================================
log_msg "Removing OUI database..."
rm -f /usr/share/devicemaster/oui.txt
rm -f /usr/share/devicemaster/oui_cache.txt
rm -f /usr/share/devicemaster/oui_append.txt
rmdir /usr/share/devicemaster 2>/dev/null

# ============================================================
# 11. Remove plugin scripts and program files
# ============================================================
log_msg "Removing plugin files..."
rm -rf /usr/libexec/devicemaster

# ============================================================
# 12. Remove LuCI files
# ============================================================
log_msg "Removing LuCI files..."
rm -f /usr/lib/lua/luci/controller/devicemaster.lua
rm -f /usr/lib/lua/luci/model/cbi/devicemaster/settings.lua
rm -rf /usr/lib/lua/luci/view/devicemaster
rm -rf /htdocs/luci-static/resources/view/devicemaster
rm -f /usr/lib/lua/luci/i18n/devicemaster.zh-cn.lmo
rm -f /usr/lib/lua/luci/i18n/devicemaster.*.lmo

# ============================================================
# Done
# ============================================================
log_msg "DeviceMaster cleanup complete!"
echo ""
echo "DeviceMaster has been fully removed."
echo "Note: You may need to restart rpcd and uhttpd:"
echo "  /etc/init.d/rpcd restart"
echo "  /etc/init.d/uhttpd restart"
