#!/bin/sh
# dhcp_guard.sh - single authoritative writer/validator for dnsmasq dhcp-host
#
# Background: dnsmasq REFUSES TO START when two dhcp-host entries reserve the
# same IP (even for the same MAC). A single duplicated reservation therefore
# takes DHCP down for the whole LAN. This library makes "check + allocate +
# write" one atomic critical section guarded by flock, and guarantees the
# invariant "one IP -> at most one dhcp-host entry" before any restart.
#
# Sourced by: sync_hostname.sh, event_handler.sh, /etc/init.d/devicemaster,
#             /etc/uci-defaults/90_devicemaster
#
# Logs: logger -t devicemaster-dhcp + /tmp/devicemaster-dhcp.log (logger is not
#       yet running during uci-defaults, the file keeps the boot-time trail).

DM_DHCP_LOCK_FILE="/tmp/dm_dhcp.lock"
DM_LOG_FILE="/tmp/devicemaster-dhcp.log"
DM_LOCK_HELD=0
DM_DHCP_BACKUP=""

dm_log() {
    logger -t devicemaster-dhcp "$1" 2>/dev/null
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$1" >> "$DM_LOG_FILE" 2>/dev/null
}

# ------------------------------------------------------------
# Critical section (flock is auto-released when the process dies)
# ------------------------------------------------------------
dm_lock_acquire() {
    [ "$DM_LOCK_HELD" = "1" ] && return 0
    exec 9>>"$DM_DHCP_LOCK_FILE" 2>/dev/null || {
        dm_log "ERROR: cannot open dhcp lock $DM_DHCP_LOCK_FILE"
        return 1
    }
    if ! flock -w "${DM_LOCK_TIMEOUT:-30}" 9; then
        dm_log "ERROR: timeout waiting for dhcp lock (${DM_LOCK_TIMEOUT:-30}s)"
        exec 9>&- 2>/dev/null
        return 1
    fi
    DM_LOCK_HELD=1
    return 0
}

dm_lock_release() {
    [ "$DM_LOCK_HELD" = "1" ] || return 0
    flock -u 9 2>/dev/null
    exec 9>&- 2>/dev/null
    DM_LOCK_HELD=0
}

# ------------------------------------------------------------
# Backup / restore of /etc/config/dhcp
# ------------------------------------------------------------
dm_dhcp_backup() {
    # Never overwrite an existing snapshot: in a batch (one process, many
    # writes) the earliest copy is the only state that predates every edit.
    if [ -n "$DM_DHCP_BACKUP" ] && [ -f "$DM_DHCP_BACKUP" ]; then
        return 0
    fi
    DM_DHCP_BACKUP="${DM_DHCP_BACKUP:-/tmp/dm_dhcp_backup.$$}"
    if ! cp -f /etc/config/dhcp "$DM_DHCP_BACKUP" 2>/dev/null; then
        DM_DHCP_BACKUP=""
        dm_log "ERROR: cannot back up /etc/config/dhcp"
        return 1
    fi
    return 0
}

dm_dhcp_restore() {
    [ -n "$DM_DHCP_BACKUP" ] && [ -f "$DM_DHCP_BACKUP" ] || return 1
    uci -q revert dhcp 2>/dev/null
    if cp -f "$DM_DHCP_BACKUP" /etc/config/dhcp 2>/dev/null; then
        dm_log "ERROR: dhcp validation failed - previous /etc/config/dhcp restored"
        rm -f "$DM_DHCP_BACKUP"
        DM_DHCP_BACKUP=""
        return 0
    fi
    return 1
}

dm_dhcp_backup_discard() {
    rm -f "$DM_DHCP_BACKUP" 2>/dev/null
    DM_DHCP_BACKUP=""
}

# ------------------------------------------------------------
# MAC / host-section helpers (never break out of the loop early)
# ------------------------------------------------------------
dm_mac_lc() {
    printf '%s' "$1" | tr 'A-F' 'a-f' | tr -d ' '
}

dm_valid_mac() {
    echo "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# Print every dhcp.@host section index, including stanzas without a mac.
# The old code used `uci get dhcp.@host[N].mac` as the loop condition, so the
# first mac-less stanza silently hid every later reservation from the
# conflict scan - exactly the failure mode that let duplicate IPs through.
dm_host_indices() {
    local i=0
    while uci -q get "dhcp.@host[$i]" >/dev/null 2>&1; do
        echo "$i"
        i=$((i + 1))
    done
}

dm_host_field() {
    uci -q get "dhcp.@host[$1].$2" 2>/dev/null
}

dm_all_macs() {
    local i m
    for i in $(dm_host_indices); do
        m=$(dm_host_field "$i" mac)
        [ -n "$m" ] && dm_mac_lc "$m"
    done
}

dm_all_ips() {
    local i ip
    for i in $(dm_host_indices); do
        ip=$(dm_host_field "$i" ip)
        [ -n "$ip" ] && echo "$ip"
    done | sort -u
}

# Owners of a static IP: "idx mac name" (one line per section)
dm_static_owners() {
    local i mac name
    for i in $(dm_host_indices); do
        [ "$(dm_host_field "$i" ip)" = "$1" ] || continue
        mac=$(dm_host_field "$i" mac)
        name=$(dm_host_field "$i" name)
        printf '%s %s %s\n' "$i" "${mac:--}" "${name:--}"
    done
}

# Delete every section belonging to a MAC (case-insensitive); print count.
dm_purge_mac() {
    local target="$1" i m count=0 list
    list=""
    for i in $(dm_host_indices); do
        m=$(dm_host_field "$i" mac)
        [ -n "$m" ] || continue
        [ "$(dm_mac_lc "$m")" = "$target" ] && list="$list $i"
    done
    for i in $(echo "$list" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn); do
        uci -q delete "dhcp.@host[$i]" && count=$((count + 1))
    done
    echo "$count"
}

# ------------------------------------------------------------
# IP evidence
# ------------------------------------------------------------
dm_lan_ip() {
    local ip
    ip=$(uci -q get network.lan.ipaddr 2>/dev/null | head -n 1)
    # New snapshots use `list ipaddr '192.168.31.1/24'` (CIDR), older ones use
    # `option ipaddr` + `option netmask`. Returning "192.168.31.1/24" made
    # ipcalc fail, so every reservation looked out-of-LAN and was stripped.
    [ -n "$ip" ] && ip="${ip%%/*}"
    [ -z "$ip" ] && ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
    echo "$ip"
}

dm_lan_mask() {
    local raw mask
    raw=$(uci -q get network.lan.ipaddr 2>/dev/null | head -n 1)
    case "$raw" in
        */*)
            # ipcalc.sh accepts a CIDR address directly ("a.b.c.d/24") and
            # answers NETMASK, but not a bare prefix ("24") as its 2nd arg.
            mask=$(ipcalc.sh "$raw" 2>/dev/null | awk -F= '$1 == "NETMASK" { print $2; exit }')
            [ -n "$mask" ] && { echo "$mask"; return; }
            ;;
    esac
    mask=$(uci -q get network.lan.netmask 2>/dev/null)
    [ -n "$mask" ] || mask=255.255.255.0
    echo "$mask"
}

dm_ipcalc_field() {
    ipcalc.sh "$1" "$2" 2>/dev/null | awk -F= -v k="$3" '$1 == k { print $2; exit }'
}

# A reservation is only accepted when it is a usable address of the LAN.
dm_ip_valid_for_lan() {
    local ip="$1" lanip mask net_lan net_ip brd
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    echo "$ip" | awk -F. '{ for (i=1; i<=4; i++) if ($i + 0 > 255) exit 1; exit 0 }' || return 1
    case "$ip" in
        0.0.0.0|169.254.*|255.*) return 1 ;;
    esac
    lanip=$(dm_lan_ip)
    [ -n "$lanip" ] || return 1
    [ "$ip" = "$lanip" ] && return 1
    # Never reserve any address that is assigned to a local interface.
    ip -4 addr show 2>/dev/null | grep -qF "inet ${ip}/" && return 1
    mask=$(dm_lan_mask)
    if command -v ipcalc.sh >/dev/null 2>&1; then
        net_lan=$(dm_ipcalc_field "$lanip" "$mask" NETWORK)
        net_ip=$(dm_ipcalc_field "$ip" "$mask" NETWORK)
        brd=$(dm_ipcalc_field "$ip" "$mask" BROADCAST)
        [ -n "$net_lan" ] && [ "$net_ip" = "$net_lan" ] || return 1
        [ "$ip" = "$brd" ] && return 1
    else
        # Fallback for images without ipcalc.sh: compare the first three octets.
        case "$ip" in
            "${lanip%.*}."*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# MAC currently holding an IP according to live evidence (lease, then ARP).
# /proc/net/arp columns: 1=IP, 2=HW type, 3=Flags, 4=HW address.
# Reading $2 here (instead of $4) yields "0x1" - the ARP line's HW type - which
# made the live-owner check useless whenever /tmp/dhcp.leases was empty.
dm_live_owner() {
    local ip="$1" mac
    mac=$(awk -v ip="$ip" '$3 == ip { print tolower($2); exit }' /tmp/dhcp.leases 2>/dev/null)
    [ -n "$mac" ] && { echo "$mac"; return; }
    mac=$(awk -v ip="$ip" '$1 == ip && $3 != "0x0" { print tolower($4); exit }' /proc/net/arp 2>/dev/null)
    [ -n "$mac" ] && echo "$mac"
}

# IP currently held by a MAC according to live evidence (lease, then ARP).
dm_mac_live_ip() {
    local mac="$1" ip
    ip=$(awk -v m="$mac" 'tolower($2) == m { print $3; exit }' /tmp/dhcp.leases 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip=$(awk -v m="$mac" 'tolower($4) == m && $3 != "0x0" { print $1; exit }' /proc/net/arp 2>/dev/null)
    [ -n "$ip" ] && echo "$ip"
}

# ------------------------------------------------------------
# Validation: reject duplicate dhcp-host IPs before restarting dnsmasq
# ------------------------------------------------------------
dm_dhcp_test() {
    local conf="/tmp/dm_dhcp_test.$$.conf" i mac ip name out rc
    : > "$conf" 2>/dev/null || {
        dm_log "WARN: cannot create $conf; skipping dnsmasq validation"
        return 0
    }
    for i in $(dm_host_indices); do
        mac=$(dm_host_field "$i" mac)
        [ -n "$mac" ] || continue
        ip=$(dm_host_field "$i" ip)
        name=$(dm_host_field "$i" name)
        if [ -n "$ip" ]; then
            printf 'dhcp-host=%s,%s%s\n' "$mac" "$ip" "${name:+,$name}" >> "$conf"
        else
            printf 'dhcp-host=%s%s\n' "$mac" "${name:+,$name}" >> "$conf"
        fi
    done
    if ! command -v dnsmasq >/dev/null 2>&1; then
        rm -f "$conf"
        dm_log "WARN: dnsmasq binary not found; skipping config validation"
        return 0
    fi
    out=$(dnsmasq --test --conf-file="$conf" 2>&1)
    rc=$?
    rm -f "$conf"
    if [ "$rc" -ne 0 ]; then
        dm_log "ERROR: dnsmasq --test rejected the new dhcp config: $out"
        return 1
    fi
    return 0
}

# Validate the committed config; roll back the file if it is invalid.
dm_dhcp_validate() {
    if dm_dhcp_test; then
        return 0
    fi
    dm_dhcp_restore
    return 1
}

dm_dnsmasq_restart_safe() {
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    sleep 2
    if ! pidof dnsmasq >/dev/null 2>&1; then
        dm_log "ERROR: dnsmasq did not come up after restart - rolling back dhcp config"
        dm_dhcp_restore && /etc/init.d/dnsmasq restart >/dev/null 2>&1
        return 1
    fi
    dm_log "dnsmasq restarted with validated dhcp config"
    return 0
}

# Finish a write: validate, then restart unless the caller is in batch mode.
# $1 = 1 when the config changed.
# On validation failure we restore the previous file and DO NOT restart:
# the running dnsmasq keeps its last-known-good config, so DHCP stays up.
dm_dhcp_finish() {
    [ "${1:-0}" = "1" ] || return 0
    if ! dm_dhcp_test; then
        dm_dhcp_restore
        dm_log "ERROR: refusing to restart dnsmasq with the rejected config"
        return 1
    fi
    [ "${SKIP_DNSMASQ_RESTART:-0}" = "1" ] && return 0
    dm_dnsmasq_restart_safe
}

# ------------------------------------------------------------
# Invariant: at most one dhcp-host entry per IP.
# Returns 1 when the config was changed.
# ------------------------------------------------------------
dm_dhcp_fix_duplicate_ips() {
    local changed=0 ip owners count keeper idx mac name live kmac kname
    for ip in $(dm_all_ips); do
        owners=$(dm_static_owners "$ip")
        count=$(echo "$owners" | grep -c .)
        [ "$count" -le 1 ] && continue
        live=$(dm_live_owner "$ip")
        keeper=""
        if [ -n "$live" ]; then
            # Compare case-insensitively: legacy entries may still hold an
            # uppercase MAC while lease/ARP evidence is lowercase. A
            # case-sensitive match here made the live holder look like a
            # stranger, so its own reservation was stripped as "stale".
            keeper=$(echo "$owners" | awk -v m="$live" 'tolower($2) == m { print $1; exit }')
            if [ -z "$keeper" ]; then
                dm_log "CONFLICT FIXED: IP $ip has no static entry for its live holder $live; all reservations for it are stale"
            fi
        fi
        [ -z "$keeper" ] && [ -z "$live" ] && keeper=$(echo "$owners" | head -1 | awk '{print $1}')
        for idx in $(echo "$owners" | awk '{print $1}'); do
            [ "$idx" = "$keeper" ] && continue
            mac=$(dm_host_field "$idx" mac)
            name=$(dm_host_field "$idx" name)
            if [ -n "$keeper" ]; then
                kmac=$(dm_host_field "$keeper" mac)
                kname=$(dm_host_field "$keeper" name)
                dm_log "CONFLICT FIXED: IP $ip was reserved by both $kmac ($kname) and $mac ($name); kept $kmac, degraded $mac to hostname-only"
            else
                dm_log "CONFLICT FIXED: stale reservation of $ip for $mac ($name); stripped ip option"
            fi
            uci -q delete "dhcp.@host[$idx].ip"
            changed=1
        done
    done
    echo "$changed"
}

# ------------------------------------------------------------
# Self-heal: normalize MACs, drop invalid stanzas, dedupe MACs and IPs.
# Caller must hold dm_lock_acquire and should have taken a backup.
# Returns 1 when the config was changed (already committed + validated).
# ------------------------------------------------------------
dm_dhcp_dedup_hosts() {
    local changed=0 i mac ip name live keeper idx list count

    # 1) Remove unparsable stanzas (no mac) - dnsmasq cannot use them and they
    #    previously hid every later section from the conflict scan.
    for i in $(dm_host_indices | sort -rn); do
        mac=$(dm_host_field "$i" mac)
        if [ -z "$mac" ]; then
            ip=$(dm_host_field "$i" ip)
            name=$(dm_host_field "$i" name)
            dm_log "WARN: removing invalid dhcp host section @host[$i] (mac empty, ip=${ip:--}, name=${name:--})"
            uci -q delete "dhcp.@host[$i]"
            changed=1
            continue
        fi
        if [ "$mac" != "$(dm_mac_lc "$mac")" ]; then
            uci -q set "dhcp.@host[$i].mac=$(dm_mac_lc "$mac")"
            dm_log "NORMALIZED: dhcp host @host[$i] mac $mac -> $(dm_mac_lc "$mac")"
            changed=1
        fi
        ip=$(dm_host_field "$i" ip)
        if [ -n "$ip" ] && ! dm_ip_valid_for_lan "$ip"; then
            dm_log "WARN: dhcp host $(dm_mac_lc "$mac") has invalid/out-of-LAN IP $ip; stripping ip option"
            uci -q delete "dhcp.@host[$i].ip"
            changed=1
        fi
    done

    # 2) Same MAC in more than one section (case differences included).
    for mac in $(dm_all_macs | sort -u); do
        list=""
        for i in $(dm_host_indices); do
            [ "$(dm_mac_lc "$(dm_host_field "$i" mac)")" = "$mac" ] && list="$list $i"
        done
        count=$(echo "$list" | wc -w)
        [ "$count" -le 1 ] && continue
        live=$(dm_mac_live_ip "$mac")
        keeper=""
        for i in $list; do
            [ -n "$live" ] && [ "$(dm_host_field "$i" ip)" = "$live" ] && { keeper=$i; break; }
        done
        if [ -z "$keeper" ]; then
            for i in $list; do
                [ -n "$(dm_host_field "$i" ip)" ] && { keeper=$i; break; }
            done
        fi
        [ -z "$keeper" ] && keeper=$(echo "$list" | awk '{print $1}')
        for i in $(echo "$list" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn); do
            [ "$i" = "$keeper" ] && continue
            dm_log "CONFLICT FIXED: duplicate dhcp host sections for MAC $mac (@host[$keeper] and @host[$i]); deleting @host[$i]"
            uci -q delete "dhcp.@host[$i]"
            changed=1
        done
    done

    # 3) Duplicate IP across MACs.
    if [ "$(dm_dhcp_fix_duplicate_ips)" = "1" ]; then
        changed=1
    fi

    if [ "$changed" = "1" ]; then
        uci -q commit dhcp
        dm_log "Self-heal: deduplicated dhcp host config committed"
        if ! dm_dhcp_validate; then
            dm_log "ERROR: deduplicated config failed dnsmasq --test; rollback kept"
            return 2
        fi
        return 1
    fi
    return 0
}
