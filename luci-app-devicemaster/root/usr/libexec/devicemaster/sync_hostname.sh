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
SAFE_NAME=$(echo "$NAME" | sed 's/[^a-zA-Z0-9._-]//g')
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

log_msg "START: $MAC -> $NAME ($IP)"

# Step 1: Remove ALL existing host entries for this MAC
# Handle index shifting: after delete, indices change
# Strategy: keep scanning from 0, break and restart after each deletion
deleted=0
while true; do
    found=0
    idx=0
    while uci -q get "dhcp.@host[$idx].mac" >/dev/null 2>&1; do
        hm=$(uci -q get "dhcp.@host[$idx].mac")
        if [ "$hm" = "$MAC" ]; then
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

# Step 2: Add new host entry
uci -q add dhcp host >/dev/null
uci -q set "dhcp.@host[-1].mac=$MAC"
uci -q set "dhcp.@host[-1].ip=$IP"
uci -q set "dhcp.@host[-1].name=$NAME"

# Step 3: Commit
uci -q commit dhcp
log_msg "UCI committed: dhcp host $MAC -> $NAME ($IP)"

# Step 4: Reload dnsmasq SYNCHRONOUSLY (no &)
# 修复：使用 reload 代替 restart，避免中断所有 DNS/DHCP 服务
# uci commit 后 dnsmasq reload 会重新读取配置，足以使新的 host 条目生效
/etc/init.d/dnsmasq reload >/dev/null 2>&1

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
