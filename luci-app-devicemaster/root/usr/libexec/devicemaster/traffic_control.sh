#!/bin/sh
# Traffic Control - Block or limit device bandwidth
# Uses nftables for modern OpenWrt versions

# Check if tc is available
TC_AVAILABLE=0
if command -v tc >/dev/null 2>&1; then
    TC_AVAILABLE=1
fi

# Fallback class of the root HTB qdisc: every packet that matches no filter is
# charged to this class. It exists only as a placeholder (we never create it),
# and mac_to_class_id() must never hand it out to a real device - see below.
HTB_DEFAULT_CLASS=10

# Reject anything that is not a MAC.
#
# Every caller in the plugin validates first, but a hand-edited UCI file or a
# manual invocation could pass an empty or junk value, and this script is not
# harmless in that case: `grep -i "" /proc/net/arp` matches every line (so an
# empty MAC silently becomes some other device's IP) and mac_to_class_id("")
# evaluates `0x*7` before falling back to class 11 - i.e. an empty MAC could
# tear down and rebuild the qdisc of the whole LAN, or set blocked=0 on the
# wrong device section.
is_valid_mac() {
    case "$1" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
    esac
    return 1
}

# Set a UCI option only when its value really changes.
#
# The schedule executor calls unblock/unlimit for every member of a group once a
# minute whenever a rule is outside its time window. Writing unconditionally
# means one `uci commit` per device per minute, i.e. /etc/config/devicemaster
# (and /etc/config/dhcp) is rewritten to flash forever, for no state change.
uci_set_if_changed() {
    local section="$1" option="$2" value="$3"
    [ -n "$section" ] || return 0
    [ "$(uci -q get "devicemaster.$section.$option" 2>/dev/null)" = "$value" ] && return 0
    uci -q set "devicemaster.$section.$option=$value"
    uci -q commit devicemaster
    return 0
}

# Find device section by MAC (using uci directly for reliability)
#
# The section itself is tested, not the mac option: @type[idx] addresses every
# section of that type, so a section without a mac (older packages shipped one)
# used to make this return "not found" - and the caller then created a second
# section for a MAC that was already configured.
#
# The comparison is case-insensitive: UCI may hold either case and a mismatch
# would produce exactly the same duplicate-section bug.
find_device_section() {
    local mac=$(echo "$1" | tr 'a-f' 'A-F')
    local idx=0
    while uci -q get "devicemaster.@device[$idx]" >/dev/null 2>&1; do
        local m=$(uci -q get "devicemaster.@device[$idx].mac" 2>/dev/null | tr 'a-f' 'A-F')
        if [ -n "$m" ] && [ "$m" = "$mac" ]; then
            echo "@device[$idx]"
            return
        fi
        idx=$((idx + 1))
    done
}

# Get IP from MAC
get_ip_from_mac() {
    local mac="$1"
    grep -i "$mac" /proc/net/arp 2>/dev/null | awk '{print $1}' | head -1
}

# Block device by MAC address
block_device() {
    local mac="$1"
    local action="$2"  # add or remove
    
    if [ "$action" = "add" ]; then
        # The table must exist before the set/chain can be added - init.d creates
        # it, but after a `nft flush ruleset` or a manual delete every later
        # `nft add ...` below fails silently (stderr is discarded), leaving UCI
        # saying "blocked" while no packet is actually dropped.
        nft add table inet devicemaster 2>/dev/null
        # Ensure blocked_macs set exists before adding elements (idempotent)
        nft add set inet devicemaster blocked_macs '{ type ether_addr; }' 2>/dev/null
        # Add MAC to blocked set
        nft add element inet devicemaster blocked_macs { "$mac" } 2>/dev/null
        
        # Ensure blocking chains exist with rules for both forward and input
        if ! nft list chain inet devicemaster dm_block 2>/dev/null | grep -q "blocked_macs"; then
            nft add chain inet devicemaster dm_block '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null
            nft add rule inet devicemaster dm_block ether saddr @blocked_macs drop 2>/dev/null
            nft add rule inet devicemaster dm_block ether daddr @blocked_macs drop 2>/dev/null
        fi
        if ! nft list chain inet devicemaster dm_block_input 2>/dev/null | grep -q "blocked_macs"; then
            nft add chain inet devicemaster dm_block_input '{ type filter hook input priority filter; policy accept; }' 2>/dev/null
            nft add rule inet devicemaster dm_block_input ether saddr @blocked_macs drop 2>/dev/null
            nft add rule inet devicemaster dm_block_input ether daddr @blocked_macs drop 2>/dev/null
        fi
        
        # Update UCI config - find existing section or create new
        local section=$(find_device_section "$mac")
        if [ -z "$section" ]; then
            section=$(uci add devicemaster device)
            uci set "devicemaster.$section.mac=$mac"
            uci commit devicemaster
        fi
        uci_set_if_changed "$section" blocked 1
        
        logger -t devicemaster "Blocked device: $mac"
        echo "success"
    elif [ "$action" = "remove" ]; then
        # Remove MAC from blocked set
        nft delete element inet devicemaster blocked_macs { "$mac" } 2>/dev/null
        
        # Update UCI config - only when the flag is actually set, so that the
        # once-a-minute unblock sweep stays completely read-only.
        local section=$(find_device_section "$mac")
        if [ -n "$section" ] && [ "$(uci -q get "devicemaster.$section.blocked" 2>/dev/null)" = "1" ]; then
            uci -q set "devicemaster.$section.blocked=0"
            uci -q commit devicemaster
        fi
        
        logger -t devicemaster "Unblocked device: $mac"
        echo "success"
    fi
}

# Limit device using nftables (fallback when tc is not available)
limit_device_nft() {
    local mac="$1"
    local rate="$2"  # e.g., "1mbit", "512kbit"
    
    # Convert rate to pps (packets per second) for nftables limit
    # This is a rough approximation: 1mbit ~ 125pps (assuming 1000 byte packets)
    local pps=125
    case "$rate" in
        *kbit) pps=$(echo "$rate" | sed 's/kbit//' | awk '{print int($1/8)}') ;;
        *mbit) pps=$(echo "$rate" | sed 's/mbit//' | awk '{print int($1*125)}') ;;
        *gbit) pps=$(echo "$rate" | sed 's/gbit//' | awk '{print int($1*125000)}') ;;
        *) pps=125 ;;
    esac
    
    # Ensure limited_macs set exists
    nft add table inet devicemaster 2>/dev/null
    nft add set inet devicemaster limited_macs '{ type ether_addr; flags timeout; timeout 1h; }' 2>/dev/null
    
    # Add MAC to limited set
    nft add element inet devicemaster limited_macs { "$mac" } 2>/dev/null
    
    # Create limit chain if not exists
    if ! nft list chain inet devicemaster dm_limit 2>/dev/null | grep -q "limited_macs"; then
        nft add chain inet devicemaster dm_limit '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null
        nft add rule inet devicemaster dm_limit ether saddr @limited_macs limit rate over "$pps/second" drop 2>/dev/null
        nft add rule inet devicemaster dm_limit ether daddr @limited_macs limit rate over "$pps/second" drop 2>/dev/null
    fi
    
    # Update UCI config
    local section=$(find_device_section "$mac")
    if [ -z "$section" ]; then
        section=$(uci add devicemaster device)
        uci set "devicemaster.$section.mac=$mac"
        uci commit devicemaster
    fi
    uci_set_if_changed "$section" rate_limit "$rate"
    
    logger -t devicemaster "Rate limited device $mac to $rate (nftables fallback)"
    echo "success"
}

# Remove nftables limit
unlimit_device_nft() {
    local mac="$1"
    
    # Remove from limited set
    nft delete element inet devicemaster limited_macs { "$mac" } 2>/dev/null
    
    # Update UCI config
    local section=$(find_device_section "$mac")
    if [ -n "$section" ] && [ -n "$(uci -q get "devicemaster.$section.rate_limit" 2>/dev/null)" ]; then
        uci -q delete "devicemaster.$section.rate_limit" 2>/dev/null
        uci -q commit devicemaster
    fi
    
    logger -t devicemaster "Removed rate limit for device $mac (nftables)"
    echo "success"
}

# Generate a stable class_id from MAC address using hash
# Uses weighted sum with prime multipliers to minimize collisions
# Range: 11-254.
#
# 1..10 are RESERVED: the root qdisc is created with "htb default 10", so
# classid 1:10 is the fallback class for every packet that matches no filter
# (i.e. all traffic of every device that is not rate limited).  If a device's
# hash landed on 10 its class would become that fallback and the whole LAN
# would inherit that device's rate.  1:1 is left alone as well because it is
# the conventional root/aggregate class id.
mac_to_class_id() {
    local mac="$1"
    local b1 b2 b3 b4 b5 b6
    # Parse MAC bytes (input format: AA:BB:CC:DD:EE:FF)
    b1=$(echo "$mac" | cut -d: -f1)
    b2=$(echo "$mac" | cut -d: -f2)
    b3=$(echo "$mac" | cut -d: -f3)
    b4=$(echo "$mac" | cut -d: -f4)
    b5=$(echo "$mac" | cut -d: -f5)
    b6=$(echo "$mac" | cut -d: -f6)
    # Weighted sum with prime multipliers: 7,13,19,29,37,43
    local sum=$(( 0x$b1*7 + 0x$b2*13 + 0x$b3*19 + 0x$b4*29 + 0x$b5*37 + 0x$b6*43 ))
    echo $(( (sum % 244) + 11 ))
}

# Limit device bandwidth using tc (traffic control)
limit_device() {
    local mac="$1"
    local rate="$2"  # e.g., "1mbit", "512kbit"
    local lan_dev="br-lan"
    
    if [ -n "$rate" ]; then
        # Applying a limit needs the device's current IP - the tc filters match
        # on ip src/dst. Removing one must NOT need it: with the check applied to
        # both branches, `unlimit` on a device that happens to be offline
        # returned "device not found in ARP table" and left the rate limit in
        # UCI (and the class in tc) in place forever.
        local ip=$(get_ip_from_mac "$mac")
        if [ -z "$ip" ]; then
            echo "error: device not found in ARP table"
            return 1
        fi

        # Check if tc is available
        if [ $TC_AVAILABLE -eq 0 ]; then
            logger -t devicemaster "tc not available, using nftables fallback for $mac"
            limit_device_nft "$mac" "$rate"
            return
        fi
        
        # Create qdisc root (idempotent)
        # NOTE: the default class id is intentionally one that
        # mac_to_class_id() never returns (see
        # HTB_DEFAULT_CLASS / the range comment on that function).
        tc qdisc add dev "$lan_dev" root handle 1: htb default "$HTB_DEFAULT_CLASS" 2>/dev/null || \
        tc qdisc replace dev "$lan_dev" root handle 1: htb default "$HTB_DEFAULT_CLASS"
        
        # Generate stable class_id from MAC (not IP last octet)
        local class_id=$(mac_to_class_id "$mac")
        
        # Remove old class and filters for this class_id first (prevent duplicates)
        tc class del dev "$lan_dev" classid "1:$class_id" 2>/dev/null
        tc filter del dev "$lan_dev" protocol ip parent 1:0 prio 1 u32 match ip dst "$ip" flowid "1:$class_id" 2>/dev/null
        tc filter del dev "$lan_dev" protocol ip parent 1:0 prio 1 u32 match ip src "$ip" flowid "1:$class_id" 2>/dev/null
        
        # Create class for this device
        tc class add dev "$lan_dev" parent 1: classid "1:$class_id" htb rate "$rate" ceil "$rate"
        
        # Add filter for this IP (only once each direction)
        tc filter add dev "$lan_dev" protocol ip parent 1:0 prio 1 u32 match ip dst "$ip" flowid "1:$class_id"
        tc filter add dev "$lan_dev" protocol ip parent 1:0 prio 1 u32 match ip src "$ip" flowid "1:$class_id"
        
        # Update UCI config
        local section=$(find_device_section "$mac")
        if [ -z "$section" ]; then
            section=$(uci add devicemaster device)
            uci set "devicemaster.$section.mac=$mac"
            uci commit devicemaster
        fi
        uci_set_if_changed "$section" rate_limit "$rate"
        
        logger -t devicemaster "Rate limited device $mac ($ip) to $rate (tc class 1:$class_id)"
        echo "success"
    else
        # Remove rate limit
        if [ $TC_AVAILABLE -eq 0 ]; then
            unlimit_device_nft "$mac"
            return
        fi

        # Strategy: save all other devices' limits, destroy qdisc, re-create others' limits
        # This is the most reliable way to remove one device's tc rules
        # (no class_id is needed here: the whole qdisc is dropped and rebuilt.)
        local remaining_limits=""
        local idx=0
        local rmac rrate
        while uci -q get "devicemaster.@device[$idx]" >/dev/null 2>&1; do
            rmac=$(uci -q get "devicemaster.@device[$idx].mac" 2>/dev/null)
            rrate=$(uci -q get "devicemaster.@device[$idx].rate_limit" 2>/dev/null)
            if [ -n "$rmac" ] && [ -n "$rrate" ] && [ "$rmac" != "$mac" ]; then
                remaining_limits="$remaining_limits $rmac $rrate"
            fi
            idx=$((idx + 1))
        done

        # Destroy the entire htb qdisc (removes all classes + filters)
        tc qdisc del dev "$lan_dev" root 2>/dev/null

        # Re-apply remaining devices' limits (will recreate htb qdisc)
        if [ -n "$remaining_limits" ]; then
            set -- $remaining_limits
            while [ $# -ge 2 ]; do
                limit_device "$1" "$2" >/dev/null 2>&1
                shift 2
            done
        fi

        # Update UCI config
        local section=$(find_device_section "$mac")
        if [ -n "$section" ] && [ -n "$(uci -q get "devicemaster.$section.rate_limit" 2>/dev/null)" ]; then
            uci -q delete "devicemaster.$section.rate_limit" 2>/dev/null
            uci -q commit devicemaster
        fi
        
        logger -t devicemaster "Removed rate limit for device $mac (tc)"
        echo "success"
    fi
}

# Get current rate limit status
get_rate_limit() {
    local mac="$1"
    local ip=$(get_ip_from_mac "$mac")
    
    # Check tc first
    if [ $TC_AVAILABLE -eq 1 ] && [ -n "$ip" ]; then
        local class_id=$(mac_to_class_id "$mac")
        tc class show dev br-lan classid "1:$class_id" 2>/dev/null | grep -o 'rate [^ ]*'
        return
    fi
    
    # Check nftables fallback
    if nft list set inet devicemaster limited_macs 2>/dev/null | grep -qi "$mac"; then
        echo "nftables-limited"
    fi
}

# List all blocked devices
list_blocked() {
    nft list set inet devicemaster blocked_macs 2>/dev/null | grep -o '([[:xdigit:]:]*)' | tr -d '()'
}

# Entry point - only execute if run directly (not sourced)
main() {
    # Normalise the MAC once, in one place.
    #
    # Everything downstream compares it against UCI values and stores it in UCI,
    # and a case mismatch used to be enough to create a duplicate device section
    # for a MAC that already existed.
    local cmd="$1"
    local mac=$(echo "$2" | tr 'a-f' 'A-F')

    case "$cmd" in
        block)
            is_valid_mac "$mac" || { echo "error: invalid mac"; exit 1; }
            block_device "$mac" "add"
            ;;
        unblock)
            is_valid_mac "$mac" || { echo "error: invalid mac"; exit 1; }
            block_device "$mac" "remove"
            ;;
        limit)
            is_valid_mac "$mac" || { echo "error: invalid mac"; exit 1; }
            limit_device "$mac" "$3"
            ;;
        unlimit)
            is_valid_mac "$mac" || { echo "error: invalid mac"; exit 1; }
            limit_device "$mac" ""
            ;;
        status)
            is_valid_mac "$mac" || { echo "error: invalid mac"; exit 1; }
            get_rate_limit "$mac"
            ;;
        list)
            list_blocked
            ;;
        *)
            echo "Usage: $0 {block|unblock|limit|unlimit|status|list} <mac> [rate]"
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly (not sourced)
[ "${0##*/}" = "traffic_control.sh" ] && main "$@"
