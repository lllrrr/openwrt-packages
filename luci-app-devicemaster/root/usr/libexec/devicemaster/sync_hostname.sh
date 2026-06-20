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

# Return all MACs (primary + alt_macs) of the devicemaster device that
# contains the given MAC. Space-separated, lowercased. Empty if not found.
get_device_macs() {
    local mac="$1"
    [ -z "$mac" ] && return
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local primary=$(uci -q get "devicemaster.@device[$idx].mac")
        local primary_lower=$(echo "$primary" | tr 'A-F' 'a-f')
        local alts=$(uci -q get "devicemaster.@device[$idx].alt_macs")
        local matched=0
        local all_macs="$primary_lower"
        if [ -n "$alts" ]; then
            local IFS=','
            for alt in $alts; do
                local alt_lower=$(echo "$alt" | tr 'A-F' 'a-f')
                [ -n "$alt_lower" ] && all_macs="$all_macs $alt_lower"
                [ "$alt_lower" = "$mac_lower" ] && matched=1
            done
            unset IFS
        fi
        if [ "$primary_lower" = "$mac_lower" ] || [ "$matched" = "1" ]; then
            echo "$all_macs"
            return
        fi
        idx=$((idx + 1))
    done
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

# ============================================================
# CRITICAL SAFETY CHECK: this MAC is an alt_mac of some device?
# Run this BEFORE IP lookup so we can clean up offline alt_macs too.
# ============================================================
# alt_macs must NOT get their own dhcp-host entry. Two reasons:
#   1. dnsmasq REFUSES to start if two dhcp-host entries share
#      the same IP (even for different MACs) -> crashloop -> no
#      DHCP at all for the whole network.
#   2. dnsmasq matches a host by primary MAC; an alt_mac can only
#      "accidentally" get a lease via the dynamic pool.
# The device's hostname is already stored against its PRIMARY MAC
# in the devicemaster UCI section; that is the single source of
# truth used for display in both the device list and DHCP leases.
#
# FIX: In addition to refusing a NEW entry, also CLEAN UP any
# existing dhcp-host entry for this alt_mac. Previously merged
# devices may already have their own dhcp-host from the old
# register_device flow, and leaving those behind causes the
# DHCP list to show an out-of-date / meaningless name.
# This check runs BEFORE IP lookup so that OFFLINE alt_macs
# (no ARP entry) are also properly cleaned up.
MAC_LOWER=$(echo "$MAC" | tr 'A-F' 'a-f')
_alt_primary=""
_alt_idx=0
while [ $_alt_idx -lt 200 ]; do
    _dm_mac=$(uci -q get "devicemaster.@device[$_alt_idx].mac" 2>/dev/null)
    [ -z "$_dm_mac" ] && break
    _alts=$(uci -q get "devicemaster.@device[$_alt_idx].alt_macs" 2>/dev/null)
    if [ -n "$_alts" ]; then
        OLD_IFS="$IFS"; IFS=','
        for _a in $_alts; do
            _a_l=$(echo "$_a" | tr -d ' ' | tr 'A-F' 'a-f')
            if [ "$_a_l" = "$MAC_LOWER" ]; then
                _alt_primary="$_dm_mac"
                break 2
            fi
        done
        IFS="$OLD_IFS"
    fi
    _alt_idx=$((_alt_idx+1))
done
if [ -n "$_alt_primary" ]; then
    log_msg "SKIP: $MAC is an alt_mac of $_alt_primary; cleaning up dhcp-host entry and clearing /tmp/dhcp.leases hostname (IP stays, DHCP list will show primary MAC's name)."
    # Clean up any stale dhcp.@host entry for this alt_mac (dnsmasq must not have
    # two dhcp-host entries for the same IP, even with different MACs)
    _deleted=0
    while true; do
        _found=0
        _idx=0
        while uci -q get "dhcp.@host[$_idx].mac" >/dev/null 2>&1; do
            _hm=$(uci -q get "dhcp.@host[$_idx].mac")
            _hm_l=$(echo "$_hm" | tr 'A-F' 'a-f')
            if [ "$_hm_l" = "$MAC_LOWER" ]; then
                uci -q delete "dhcp.@host[$_idx]"
                _deleted=$((_deleted + 1))
                _found=1
                break
            fi
            _idx=$((_idx + 1))
        done
        [ "$_found" = "0" ] && break
    done
    if [ "$_deleted" -gt 0 ]; then
        uci -q commit dhcp
    fi
    # FIX: Instead of deleting the /tmp/dhcp.leases line (which removes the IP
    # from the DHCP list), update the hostname to "*" so the DHCP list
    # will show this IP under the primary MAC's name.
    # The primary MAC's dhcp.@host entry carries the authoritative name.
    if [ -f "/tmp/dhcp.leases" ]; then
        sed -i "/[[:space:]]${MAC_LOWER}[[:space:]]/{ s/^\([0-9]*[[:space:]]*[a-fA-F0-9:]*[[:space:]]*[0-9.]*[[:space:]]*\)[^[:space:]]*/\1*/ }" /tmp/dhcp.leases
    fi
    [ "$_deleted" -gt 0 ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1
    log_msg "Cleaned $_deleted stale dhcp-host entries for alt_mac $MAC; lease hostname cleared."
    echo "OK: alt_mac skipped (cleaned $_deleted dhcp-host entries; lease hostname cleared to *)"
    exit 0
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

# ============================================================
# SECOND SAFETY CHECK: reject "automatically generated" hostnames
# ============================================================
# DeviceMaster invents placeholder names such as "Mobile-Device-phone"
# from OUI + device-type, or "*"/"unknown" when nothing is known.
# Writing these to dnsmasq pollutes the DHCP list.  Only sync a
# lease when we have a meaningful hostname.
case "$NAME" in
    ''|*'*'*|*unknown*)
        log_msg "SKIP: placeholder hostname '$NAME' for $MAC"
        echo "OK: placeholder name skipped"
        exit 0
        ;;
esac
# Additional check: common auto-generated patterns
_name_lower=$(echo "$NAME" | tr 'A-Z' 'a-z')
case "$_name_lower" in
    mobile-device-*|*-device-phone|*-device-pc|*-device-iot|*-device-laa)
        log_msg "SKIP: auto-generated hostname '$NAME' for $MAC"
        echo "OK: auto-generated name skipped"
        exit 0
        ;;
esac

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
# 合并设备的 alt_macs 与主 MAC 属于同一逻辑设备，允许共享 hostname。
DEVICE_MACS=$(get_device_macs "$MAC")
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
            # 同一 devicemaster 设备（主 MAC + alt_macs）允许同名
            if ! echo " $DEVICE_MACS " | grep -q " $dhcp_mac_lower "; then
                dup_dhcp="$dhcp_line"
            fi
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
            # 同一 devicemaster 设备（主 MAC + alt_macs）允许同名
            if ! echo " $DEVICE_MACS " | grep -q " $dm_mac_lower "; then
                dup_dm_name="$dm_line"
            fi
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
            # 同一 devicemaster 设备（主 MAC + alt_macs）允许同名
            if ! echo " $DEVICE_MACS " | grep -q " $dm_mac_lower "; then
                dup_dm_hostname="$dm_line"
            fi
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
# When called in batch mode (e.g. from reidentify/discover sync loops), caller
# will restart dnsmasq once at the end to avoid N restarts for N devices.
if [ "${SKIP_DNSMASQ_RESTART:-0}" != "1" ]; then
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
else
    log_msg "Batch mode: skipping dnsmasq restart for $MAC"
    echo "OK"
fi

exit 0
