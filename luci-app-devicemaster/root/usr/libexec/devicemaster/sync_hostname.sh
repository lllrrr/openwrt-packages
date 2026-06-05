#!/bin/sh
# sync_hostname.sh - Sync device hostname to dnsmasq static lease
# Usage: sync_hostname.sh <mac> <name> [ip]
#
# This script handles the full lifecycle:
# 1. Remove ALL existing dhcp host entries for this MAC
# 2. Add a new dhcp host entry with the given name
# 3. Restart dnsmasq (not reload - reload doesn't flush DNS cache)
#
# Called by: devicemaster.lua (api_set_name) and event_handler.sh (register_device)
#
# IMPORTANT: This script runs SYNCHRONOUSLY (no & background).
# The caller must wait for it to complete.

MAC="$1"
NAME="$2"
IP="$3"

LOG_TAG="devicemaster-sync"

log_msg() {
    logger -t "$LOG_TAG" "$1"
}

# Validate
if [ -z "$MAC" ]; then
    log_msg "ERROR: Missing MAC argument"
    echo "ERROR: Missing MAC"
    exit 1
fi
if [ -z "$NAME" ]; then
    log_msg "ERROR: Missing NAME argument"
    echo "ERROR: Missing NAME"
    exit 1
fi

# Sanitize hostname: dnsmasq only allows [a-zA-Z0-9._-]
# Non-ASCII characters (e.g. Chinese) will cause dnsmasq to crash!
# RFC 1035: hostname max length is 63 characters per label
SAFE_NAME=$(echo "$NAME" | sed 's/[^a-zA-Z0-9._-]//g' | cut -c1-63)
if [ -z "$SAFE_NAME" ]; then
    log_msg "ERROR: Name '$NAME' has no valid DNS characters after sanitization"
    echo "ERROR: Invalid hostname"
    exit 1
fi
if [ "$SAFE_NAME" != "$NAME" ]; then
    log_msg "WARN: Sanitized hostname '$NAME' -> '$SAFE_NAME' (removed non-ASCII chars)"
    NAME="$SAFE_NAME"
fi

# If IP not provided, look it up from ARP
if [ -z "$IP" ]; then
    IP=$(grep -i "$MAC" /proc/net/arp 2>/dev/null | awk '{print $1}' | head -1)
fi
if [ -z "$IP" ]; then
    log_msg "ERROR: Cannot find IP for $MAC in ARP table (device may be offline)"
    echo "ERROR: No IP found for $MAC"
    exit 1
fi

# Concurrent lock (atomic mkdir)
LOCK="/tmp/dm_sync_hostname.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    log_msg "ERROR: Another sync in progress, aborting"
    echo "ERROR: Another sync in progress"
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

log_msg "START: $MAC -> $NAME ($IP)"

# Step 1: Remove ALL existing host entries for this MAC
# Handle index shifting: after delete, indices change
# Strategy: keep scanning from 0, break and restart after each deletion
# IMPORTANT: Compare MACs case-insensitively (UCI may store in different cases)
MAC_LOWER=$(echo "$MAC" | tr 'A-F' 'a-f')
deleted=0
while true; do
    found=0
    idx=0
    while uci -q get "dhcp.@host[$idx].mac" >/dev/null 2>&1; do
        hm=$(uci -q get "dhcp.@host[$idx].mac")
        hm_lower=$(echo "$hm" | tr 'A-F' 'a-f')
        if [ "$hm_lower" = "$MAC_LOWER" ]; then
            uci -q delete "dhcp.@host[$idx]"
            deleted=$((deleted + 1))
            found=1
            break  # Restart scan from 0 (indices shifted)
        fi
        idx=$((idx + 1))
    done
    [ "$found" = "0" ] && break
done
log_msg "Deleted $deleted old host entries for $MAC"

# 修复：删除后立即 commit，确保检测时旧条目已清除
uci -q commit dhcp

# Step 2: Check for duplicate hostnames and add suffix if needed
# 修复：检查 devicemaster 和 dhcp 中的名称，与 LuCI unique_name 保持一致
# 注意：需要正确排除自己，不能直接用 grep -v MAC，因为 uci show 输出格式不同
base_name="$NAME"
counter=1
final_name="$NAME"
while true; do
    # Check if this name is already used by another MAC in dhcp
    dup_dhcp=""
    dhcp_line=$(uci show dhcp 2>/dev/null | grep "\.name='${final_name}'" | head -1)
    if [ -n "$dhcp_line" ]; then
        # Extract index from dhcp entry (format: dhcp.@host[N].name='...')
        dhcp_idx=$(echo "$dhcp_line" | grep -o '@host\[[0-9]*\]' | grep -o '[0-9]*')
        dhcp_mac=$(uci -q get "dhcp.@host[$dhcp_idx].mac" 2>/dev/null)
        dhcp_mac_lower=$(echo "$dhcp_mac" | tr 'A-F' 'a-f')
        if [ "$dhcp_mac_lower" != "$MAC_LOWER" ]; then
            dup_dhcp="$dhcp_line"
        fi
    fi

    # Check if this name is already used by another MAC in devicemaster (name field)
    dup_dm_name=""
    dm_line=$(uci show devicemaster 2>/dev/null | grep "\.name='${final_name}'" | head -1)
    if [ -n "$dm_line" ]; then
        # Extract section name (format: devicemaster.@device[N].name='...' or devicemaster.XXXXXX.name='...')
        dm_section=$(echo "$dm_line" | grep -o '@device\[[0-9]*\]')
        [ -z "$dm_section" ] && dm_section=$(echo "$dm_line" | sed 's/^devicemaster\.\([^=]*\)\..*/\1/')
        dm_mac=$(uci -q get "devicemaster.$dm_section.mac" 2>/dev/null)
        dm_mac_lower=$(echo "$dm_mac" | tr 'A-F' 'a-f')
        if [ "$dm_mac_lower" != "$MAC_LOWER" ]; then
            dup_dm_name="$dm_line"
        fi
    fi

    # Check if this name is already used by another MAC in devicemaster (hostname field)
    dup_dm_hostname=""
    dm_line=$(uci show devicemaster 2>/dev/null | grep "\.hostname='${final_name}'" | head -1)
    if [ -n "$dm_line" ]; then
        # Extract section name
        dm_section=$(echo "$dm_line" | grep -o '@device\[[0-9]*\]')
        [ -z "$dm_section" ] && dm_section=$(echo "$dm_line" | sed 's/^devicemaster\.\([^=]*\)\..*/\1/')
        dm_mac=$(uci -q get "devicemaster.$dm_section.mac" 2>/dev/null)
        dm_mac_lower=$(echo "$dm_mac" | tr 'A-F' 'a-f')
        if [ "$dm_mac_lower" != "$MAC_LOWER" ]; then
            dup_dm_hostname="$dm_line"
        fi
    fi

    if [ -z "$dup_dhcp" ] && [ -z "$dup_dm_name" ] && [ -z "$dup_dm_hostname" ]; then
        break
    fi
    # Name exists, try with suffix
    counter=$((counter + 1))
    final_name="${base_name}-${counter}"
    # Prevent infinite loop
    [ "$counter" -gt 100 ] && break
done

if [ "$final_name" != "$NAME" ]; then
    log_msg "WARN: Name '$NAME' already used by another device, using '$final_name' instead"
    NAME="$final_name"
fi

# Step 3: Add new host entry
uci -q add dhcp host >/dev/null
uci -q set "dhcp.@host[-1].mac=$MAC"
uci -q set "dhcp.@host[-1].ip=$IP"
uci -q set "dhcp.@host[-1].name=$NAME"

# Step 3: Commit
uci -q commit dhcp
log_msg "UCI committed: dhcp host $MAC -> $NAME ($IP)"

# Step 4: Patch /tmp/dhcp.leases to update hostname in-place
# This makes LuCI's DHCP lease page show the custom name immediately,
# instead of the client-reported hostname (e.g. "Applephone" -> "iphone13pro")
# /tmp/dhcp.leases format: <timestamp> <mac> <ip> <hostname> <clientid>
DHCP_LEASES="/tmp/dhcp.leases"
if [ -f "$DHCP_LEASES" ]; then
    # Use sed to replace hostname for matching MAC (case-insensitive)
    # The hostname is the 4th field in the lease line
    MAC_SED=$(echo "$MAC_LOWER" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    sed -i "/[[:space:]]${MAC_SED}[[:space:]]/{
        s/^\([0-9]*[[:space:]]*[a-fA-F0-9:]*[[:space:]]*[0-9.]*[[:space:]]*\)[^[:space:]]*/\1${NAME}/
    }" "$DHCP_LEASES"
    log_msg "Patched dhcp.leases hostname for $MAC -> $NAME"
fi

# Step 5: Restart dnsmasq to apply all changes
# Use restart instead of reload to flush DNS cache and pick up lease file changes
/etc/init.d/dnsmasq restart >/dev/null 2>&1

# Verify: use nslookup to confirm DNS resolution works
sleep 1
if nslookup "$NAME" 127.0.0.1 >/dev/null 2>&1; then
    log_msg "OK: DNS lookup for $NAME succeeded"
    echo "OK"
else
    log_msg "WARN: DNS lookup for $NAME failed after restart"
    echo "WARN: DNS verification failed"
fi

exit 0
