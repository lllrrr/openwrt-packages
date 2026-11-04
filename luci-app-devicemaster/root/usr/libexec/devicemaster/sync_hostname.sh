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
# --no-ip: write a hostname-only binding (merged devices / offline primary).
# Offline MACs must never take a fixed IP away from the device that really
# holds it; that is what produced duplicate dhcp-host IPs in the past.
NO_IP=0
case "${3:-}" in
    --no-ip|--noip) NO_IP=1; IP="" ;;
esac
[ "${4:-}" = "--no-ip" ] && NO_IP=1
[ "$NO_IP" = "1" ] && IP=""

LOG_TAG="devicemaster-sync"

log_msg() {
    logger -t "$LOG_TAG" "$1"
}

# Single authoritative dhcp writer: flock-protected upsert + dedupe +
# dnsmasq --test validation. Refuse to run if it is missing rather than
# writing dhcp-host entries without the uniqueness guarantee.
DHCP_GUARD="/usr/libexec/devicemaster/dhcp_guard.sh"
if [ -f "$DHCP_GUARD" ]; then
    . "$DHCP_GUARD"
else
    log_msg "ERROR: $DHCP_GUARD missing; refusing to modify dhcp config"
    echo "ERROR: dhcp_guard.sh missing"
    exit 1
fi

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

# All dhcp-host writes use lowercase MACs. Previously the event handler fed
# uppercase MACs while LuCI fed lowercase, which defeated the case-sensitive
# duplicate scans and let the same MAC be written twice.
MAC=$(dm_mac_lc "$MAC")
if ! dm_valid_mac "$MAC"; then
    log_msg "ERROR: Invalid MAC '$MAC'"
    echo "ERROR: Invalid MAC"
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
    # Resolve the authoritative display name for the merged device:
    # use the primary's hostname, falling back to its manual name.
    _alt_display=""
    _alt_hn=$(uci -q get "devicemaster.@device[$_alt_idx].hostname" 2>/dev/null)
    _alt_nm=$(uci -q get "devicemaster.@device[$_alt_idx].name" 2>/dev/null)
    _alt_manual=$(uci -q get "devicemaster.@device[$_alt_idx].manual" 2>/dev/null)
    if [ -n "$_alt_hn" ] && [ "$_alt_hn" != "*" ] && [ "$_alt_hn" != "unknown" ]; then
        case "$_alt_hn" in
            Mobile-Device-*|*-Device-phone|*-Device-pc|*-Device-iot|*-Device-tv|*-Device-laa) ;;
            *) _alt_display="$_alt_hn" ;;
        esac
    fi
    if [ -z "$_alt_display" ]; then
        if [ "$_alt_manual" = "1" ] && [ -n "$_alt_nm" ] && [ "$_alt_nm" != "*" ] && [ "$_alt_nm" != "unknown" ]; then
            _alt_display="$_alt_nm"
        fi
    fi
    [ -z "$_alt_display" ] && _alt_display="*"

    log_msg "ALT_MAC: $MAC is alt_mac of $_alt_primary (display: $_alt_display); syncing hostname-only lease."

    # Optimization: if the only existing entry for this alt_mac is already a
    # hostname-only entry with the desired name, skip the delete/add cycle and
    # just patch /tmp/dhcp.leases.
    _alt_existing_ok=0
    _alt_existing_count=0
    for _alt_idx2 in $(dm_host_indices); do
        _ehm=$(dm_host_field "$_alt_idx2" mac)
        _ehm_l=$(dm_mac_lc "$_ehm")
        if [ "$_ehm_l" = "$MAC_LOWER" ]; then
            _alt_existing_count=$((_alt_existing_count + 1))
            _eip=$(dm_host_field "$_alt_idx2" ip)
            _enm=$(dm_host_field "$_alt_idx2" name)
            if [ -z "$_eip" ] && [ "$_enm" = "$_alt_display" ]; then
                _alt_existing_ok=1
            else
                _alt_existing_ok=0
            fi
        fi
    done
    if [ "$_alt_existing_count" -eq 1 ] && [ "$_alt_existing_ok" = "1" ]; then
        if [ -f "/tmp/dhcp.leases" ]; then
            awk -v m="$MAC_LOWER" -v name="$_alt_display" '
                tolower($2) == m { $4 = name; found = 1 }
                { print }
                END { exit 0 }
            ' /tmp/dhcp.leases > /tmp/dhcp.leases.dmtmp && mv /tmp/dhcp.leases.dmtmp /tmp/dhcp.leases
        fi
        log_msg "ALT_MAC entry already correct for $MAC -> $_alt_display; lease file patched only."
        echo "OK: alt_mac already configured"
        exit 0
    fi

    # Serialize against every other dhcp writer (event handler, LuCI merge,
    # cron) before touching the config, and keep a rollback copy.
    dm_lock_acquire || { log_msg "ERROR: dhcp lock unavailable for alt_mac $MAC"; echo "ERROR: busy"; exit 1; }
    trap 'dm_lock_release; dm_dhcp_backup_discard' EXIT INT TERM
    uci -q revert dhcp 2>/dev/null
    dm_dhcp_backup || {
        log_msg "ERROR: cannot back up /etc/config/dhcp for alt_mac $MAC"
        echo "ERROR: backup failed"
        exit 1
    }

    # Clean up any stale dhcp.@host entry for this alt_mac.  Previously merged
    # devices may have a fixed-IP entry from before merge; dnsmasq refuses to
    # start if two entries share the same IP, so these must be removed.
    _deleted=$(dm_purge_mac "$MAC_LOWER")

    # For alt_macs we cannot reserve a fixed IP (it would conflict with the
    # primary MAC's lease), but we CAN pin the hostname via a hostname-only
    # dhcp-host entry.  This makes dnsmasq report the merged device's name for
    # the alt_mac's lease on every renewal, instead of '*'/'-'.
    _alt_need_commit=0
    [ "$_deleted" -gt 0 ] && _alt_need_commit=1
    _alt_entry_added=0
    if [ "$_alt_display" != "*" ]; then
        _alt_sec=$(uci add dhcp host 2>/dev/null)
        if [ -z "$_alt_sec" ]; then
            log_msg "ERROR: uci add dhcp host failed for alt_mac $MAC"
            dm_dhcp_restore
            echo "ERROR: add failed"
            exit 1
        fi
        uci -q set "dhcp.$_alt_sec.mac=$MAC_LOWER"
        uci -q set "dhcp.$_alt_sec.name=$_alt_display"
        # Do NOT set ip -> dynamic IP, hostname fixed
        _alt_need_commit=1
        _alt_entry_added=1
    fi

    if [ "$_alt_need_commit" -gt 0 ]; then
        uci -q commit dhcp
    fi

    # Patch /tmp/dhcp.leases immediately so the LuCI DHCP list reflects the
    # merged name right away (dnsmasq also rewrites the lease file on renewal).
    if [ -f "/tmp/dhcp.leases" ]; then
        awk -v m="$MAC_LOWER" -v name="$_alt_display" '
            tolower($2) == m { $4 = name; found = 1 }
            { print }
            END { exit 0 }
        ' /tmp/dhcp.leases > /tmp/dhcp.leases.dmtmp && mv /tmp/dhcp.leases.dmtmp /tmp/dhcp.leases
    fi

    if [ "$_alt_need_commit" -gt 0 ]; then
        dm_dhcp_finish "$_alt_need_commit" || {
            log_msg "ERROR: dnsmasq validation failed for alt_mac $MAC"
            echo "ERROR: validation failed"
            exit 1
        }
    fi
    log_msg "ALT_MAC done: $MAC -> $_alt_display (deleted $_deleted old entries, hostname-only added: $_alt_entry_added)."
    echo "OK: alt_mac synced (display: $_alt_display, hostname-only added: $_alt_entry_added)"
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

# IP resolution order when the caller did not supply one:
#   1. this MAC's existing reservation  -> renaming an offline device keeps it
#   2. live lease (factual evidence)
#   3. ARP entry (factual, shorter-lived)
# Never use devicemaster's last_ip: it goes stale and was the source of
# "offline device steals the IP another device is using".
if [ "$NO_IP" != "1" ] && [ -z "$IP" ]; then
    for _r_i in $(dm_host_indices); do
        [ "$(dm_mac_lc "$(dm_host_field "$_r_i" mac)")" = "$MAC" ] || continue
        _r_ip=$(dm_host_field "$_r_i" ip)
        [ -n "$_r_ip" ] && { IP="$_r_ip"; break; }
    done
fi
if [ "$NO_IP" != "1" ] && [ -z "$IP" ]; then
    IP=$(dm_mac_live_ip "$MAC")
fi
if [ "$NO_IP" != "1" ] && [ -z "$IP" ]; then
    log_msg "ERROR: Cannot find IP for $MAC in leases/ARP (device may be offline)"
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
    mobile-device-*|*-device-phone|*-device-pc|*-device-iot|*-device-tv|*-device-laa)
        log_msg "SKIP: auto-generated hostname '$NAME' for $MAC"
        echo "OK: auto-generated name skipped"
        exit 0
        ;;
esac
# Also skip if hostname is a full MAC address (XX:XX:XX:XX:XX:XX)
if echo "$NAME" | grep -qiE '^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$'; then
    log_msg "SKIP: hostname '$NAME' looks like a MAC address for $MAC"
    echo "OK: MAC-as-hostname skipped"
    exit 0
fi

# One flock-protected critical section for "check + allocate + write".
# flock is released by the kernel even if the process is SIGKILLed, so the
# abandoned-mkdir-lock problem (every later sync aborting until reboot)
# cannot happen. All other dhcp writers use the same lock file.
dm_lock_acquire || {
    log_msg "ERROR: Another dhcp writer holds the lock, aborting"
    echo "ERROR: Another sync in progress"
    exit 1
}
trap 'dm_lock_release; dm_dhcp_backup_discard' EXIT INT TERM

# Drop any orphaned pending delta left by a killed process; the committed
# /etc/config/dhcp is untouched. Prevents a later commit from applying
# half-finished edits made by a previous crashed sync.
uci -q revert dhcp 2>/dev/null

dm_dhcp_backup || {
    log_msg "ERROR: cannot back up /etc/config/dhcp, aborting"
    echo "ERROR: backup failed"
    exit 1
}

log_msg "START: $MAC -> $NAME (${IP:-hostname-only})"

# Optimization: if the exact desired dhcp-host entry already exists, do not
# delete/re-add/restart dnsmasq.  Just patch /tmp/dhcp.leases in case dnsmasq
# overwrote it since our last run (e.g. after a DHCP renewal).
MAC_LOWER="$MAC"
# An entry only counts as "already configured" when it is the ONLY stanza for
# this MAC and its IP is a usable LAN address. Otherwise we fall through to the
# purge/rewrite path: a second stanza for the same MAC (legacy uppercase twin)
# or an out-of-LAN reservation left by an older plugin version must be repaired
# here, not preserved until the next reboot.
_desired_exists=0
_mac_sections=0
for _desired_idx in $(dm_host_indices); do
    _dhm=$(dm_host_field "$_desired_idx" mac)
    _dhm_l=$(dm_mac_lc "$_dhm")
    [ "$_dhm_l" = "$MAC_LOWER" ] || continue
    _mac_sections=$((_mac_sections + 1))
    _dhip=$(dm_host_field "$_desired_idx" ip)
    _dhn=$(dm_host_field "$_desired_idx" name)
    if [ "$_dhip" = "$IP" ] && [ "$_dhn" = "$NAME" ] \
        && { [ -z "$_dhip" ] || dm_ip_valid_for_lan "$_dhip"; }; then
        _desired_exists=1
    fi
done
[ "$_mac_sections" -eq 1 ] || _desired_exists=0
if [ "$_desired_exists" = "1" ]; then
    # An already-correct entry does not excuse stale duplicates elsewhere:
    # heal them before returning, otherwise dnsmasq may still refuse to start.
    _inv=$(dm_dhcp_fix_duplicate_ips)
    if [ "$_inv" = "1" ]; then
        uci -q commit dhcp
        dm_dhcp_finish 1 || {
            log_msg "ERROR: duplicate heal failed validation for $MAC"
            echo "ERROR: validation failed"
            exit 1
        }
        log_msg "Self-heal: duplicate IP reservations fixed while checking $MAC"
    fi
    if [ -f "/tmp/dhcp.leases" ]; then
        awk -v m="$MAC_LOWER" -v name="$NAME" '
            tolower($2) == m { $4 = name; found = 1 }
            { print }
            END { exit 0 }
        ' /tmp/dhcp.leases > /tmp/dhcp.leases.dmtmp && mv /tmp/dhcp.leases.dmtmp /tmp/dhcp.leases
    fi
    log_msg "Entry already exists for $MAC -> $NAME (${IP:-hostname-only}); lease file patched."
    echo "OK: already configured"
    exit 0
fi

# Step 1: Remove ALL existing host entries for this MAC.
# dm_purge_mac enumerates every @host section (including mac-less ones) and
# compares MACs case-insensitively, so no stale twin can survive.
deleted=$(dm_purge_mac "$MAC_LOWER")
log_msg "Deleted $deleted old host entries for $MAC"

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

# Step 2.5: authoritative IP decision.
# dnsmasq REFUSES TO START when two dhcp-host entries share the same IP
# (fatal even if the MACs differ) -> crashloop -> DHCP down for the whole
# network. The decision below is the ONLY place a reservation is granted:
#   * the IP must be a usable LAN address (not router/local/network/broadcast)
#   * if live evidence (lease/ARP) says another MAC holds it, this MAC gets no IP
#   * if another MAC owns the static entry and this MAC has no live evidence,
#     the existing reservation wins and this MAC gets a hostname-only binding.
#     (Previously the caller's stale last_ip stole it back and forth.)
#   * if this MAC really holds it (live lease/ARP), the other reservation is
#     provably stale and is stripped.
_use_ip="$IP"
_ip_conflict=0
if [ -n "$_use_ip" ] && ! dm_ip_valid_for_lan "$_use_ip"; then
    log_msg "WARN: IP $_use_ip for $MAC is outside the LAN (router $(dm_lan_ip)); writing hostname-only binding"
    _use_ip=""
fi
if [ -n "$_use_ip" ]; then
    _live_owner=$(dm_live_owner "$_use_ip")
    if [ -n "$_live_owner" ] && [ "$_live_owner" != "$MAC_LOWER" ]; then
        log_msg "WARN: IP $_use_ip is currently held by $_live_owner (lease/ARP); $MAC gets hostname-only binding"
        _use_ip=""
    fi
fi
if [ -n "$_use_ip" ]; then
    _owners=$(dm_static_owners "$_use_ip")
    if [ -n "$_owners" ]; then
        _my_live=$(dm_mac_live_ip "$MAC_LOWER")
        if [ "$_my_live" = "$_use_ip" ]; then
            for _oi in $(echo "$_owners" | awk '{print $1}'); do
                _om=$(dm_host_field "$_oi" mac)
                _on=$(dm_host_field "$_oi" name)
                log_msg "CONFLICT FIXED: IP $_use_ip was reserved by $_om ($_on); the live lease belongs to $MAC, stripping the stale reservation"
                uci -q delete "dhcp.@host[$_oi].ip"
                _ip_conflict=1
            done
        else
            _owner_line=$(echo "$_owners" | head -1)
            _om=$(echo "$_owner_line" | awk '{print $2}')
            _on=$(echo "$_owner_line" | cut -d' ' -f3-)
            log_msg "WARN: IP $_use_ip already reserved by $_om ($_on); $MAC has no live evidence for it, keeping the existing reservation (hostname-only binding)"
            _use_ip=""
        fi
    fi
fi

# Step 3: Add exactly one host entry for this MAC.
_sec=$(uci add dhcp host 2>/dev/null)
if [ -z "$_sec" ]; then
    log_msg "ERROR: uci add dhcp host failed for $MAC"
    dm_dhcp_restore
    echo "ERROR: add failed"
    exit 1
fi
uci -q set "dhcp.$_sec.mac=$MAC"
uci -q set "dhcp.$_sec.name=$NAME"
[ -n "$_use_ip" ] && uci -q set "dhcp.$_sec.ip=$_use_ip"

# Final invariant scan (heals legacy duplicates elsewhere in the file too).
_inv=$(dm_dhcp_fix_duplicate_ips)

# Step 3b: one commit, then dnsmasq --test before any restart.
uci -q commit dhcp
if [ "$_inv" = "1" ]; then
    log_msg "CONFLICT FIXED: duplicate IP reservation(s) healed while writing $MAC"
fi
dm_dhcp_finish 1 || {
    log_msg "ERROR: dnsmasq rejected the new dhcp config; previous config restored for $MAC"
    echo "ERROR: validation failed"
    exit 1
}
log_msg "UCI committed: dhcp host $MAC -> $NAME (${_use_ip:-hostname-only})"

# Step 4: Patch /tmp/dhcp.leases to update hostname in-place
# This makes LuCI's DHCP lease page show the custom name immediately,
# instead of the client-reported hostname (e.g. "Applephone" -> "iphone13pro")
# /tmp/dhcp.leases format: <timestamp> <mac> <ip> <hostname> <clientid>
DHCP_LEASES="/tmp/dhcp.leases"
if [ -f "$DHCP_LEASES" ]; then
    # Use awk for case-insensitive MAC matching and hostname replacement.
    # The hostname is the 4th field in the lease line.
    awk -v m="$MAC_LOWER" -v name="$NAME" '
        tolower($2) == m { $4 = name; found = 1 }
        { print }
        END { exit 0 }
    ' "$DHCP_LEASES" > "$DHCP_LEASES.dmtmp" && mv "$DHCP_LEASES.dmtmp" "$DHCP_LEASES"
    log_msg "Patched dhcp.leases hostname for $MAC -> $NAME"
fi

# Step 5: dnsmasq was already validated and restarted by dm_dhcp_finish()
# (unless batch mode). Verify DNS resolution without restarting a second time.
if [ "${SKIP_DNSMASQ_RESTART:-0}" != "1" ]; then
    sleep 1
    if nslookup "$NAME" 127.0.0.1 >/dev/null 2>&1; then
        log_msg "OK: DNS lookup for $NAME succeeded"
        echo "OK"
    else
        log_msg "WARN: DNS lookup for $NAME failed after restart"
        echo "WARN: DNS verification failed"
    fi
else
    log_msg "Batch mode: dhcp config validated, dnsmasq restart deferred for $MAC"
    echo "OK"
fi

exit 0
