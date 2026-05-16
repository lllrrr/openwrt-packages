#!/bin/sh
# DeviceMaster Data Collector
# Collects device information from DHCP leases, ARP table, OUI database,
# mDNS/Bonjour, DHCP fingerprinting, and traffic analysis

OUI_DB="/usr/share/devicemaster/oui.txt"
OUI_CACHE="/usr/share/devicemaster/oui_cache.txt"
OUI_LOOKUP_CACHE="/tmp/devicemaster_oui_cache.txt"
DHCP_LEASES="/tmp/dhcp.leases"
ARP_TABLE="/proc/net/arp"
MDNS_CACHE="/tmp/devicemaster_mdns_cache"
DHCP_FINGERPRINT_DB="/usr/share/devicemaster/dhcp_fingerprints.txt"
FAST_AWK_SCRIPT="/tmp/fast_update.awk"

# ============================================================
# Data Sources
# ============================================================

# Get DHCP leases - Format: timestamp mac ip hostname *
get_dhcp_leases() {
    if [ -f "$DHCP_LEASES" ]; then
        awk '{print $3","$2","$4}' "$DHCP_LEASES"
    fi
}

# Get ARP table entries
get_arp_entries() {
    awk 'NR>1 && $4!="00:00:00:00:00:00" {print $1","$4","$6}' "$ARP_TABLE" 2>/dev/null
}

# ============================================================
# OUI Lookup
# ============================================================

# Source OUI lookup module
OUI_LOOKUP="/usr/libexec/devicemaster/oui_lookup.sh"

# Wrapper for OUI lookup - uses external module if available
lookup_oui() {
    local mac="$1"

    # Use new OUI lookup module if available
    if [ -f "$OUI_LOOKUP" ]; then
        local vendor=$($OUI_LOOKUP lookup "$mac" 2>/dev/null)
        if [ -n "$vendor" ] && [ "$vendor" != "Unknown" ]; then
            # Truncate at " Co." to shorten long names
            echo "$vendor" | sed 's/ Co\..*$//'
            return
        fi
    fi

    # Fallback to legacy local database lookup
    local oui=$(echo "$mac" | tr -d ':' | cut -c1-6 | tr 'a-f' 'A-F')
    if [ -f "$OUI_DB" ]; then
        local vendor=$(grep -i "^$oui" "$OUI_DB" | cut -d'|' -f2 | head -1)
        echo "$vendor" | sed 's/ Co\..*$//'
    fi
}

# ============================================================
# Random MAC Detection (LAA)
# ============================================================

# Check if MAC is randomized (Locally Administered Address)
# LAA: bit 1 of first octet is set (0x02)
# Examples: x2:xx, x6:xx, xA:xx, xE:xx
is_randomized_mac() {
    local mac="$1"
    local first_byte=$(echo "$mac" | cut -d':' -f1)
    local dec=$(printf "%d" "0x$first_byte" 2>/dev/null)
    [ $((dec & 0x02)) -ne 0 ]
}

# ============================================================
# mDNS / Bonjour Detection (for Apple devices)
# ============================================================

# Probe mDNS for a specific IP to discover device info
# Uses nslookup (available on most OpenWrt) or avahi if installed
mdns_probe_ip() {
    local ip="$1"
    local result=""

    # Method 1: avahi-browse (most reliable, if installed)
    if command -v avahi-browse >/dev/null 2>&1; then
        result=$(avahi-browse -a -t -r -p 2>/dev/null | grep -i "$ip" | head -1)
        if [ -n "$result" ]; then
            echo "$result" | awk -F';' '{print $4}' | sed 's/\.local$//'
            return
        fi
    fi

    # Method 2: avahi-resolve (if installed)
    if command -v avahi-resolve >/dev/null 2>&1; then
        result=$(avahi-resolve-host-name -a "$ip" 2>/dev/null | awk '{print $2}')
        if [ -n "$result" ]; then
            echo "$result" | sed 's/\.local$//'
            return
        fi
    fi

    # Method 3: nslookup reverse lookup (always available)
    if command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup "$ip" 2>/dev/null | grep "name = " | head -1)
        if [ -n "$result" ]; then
            echo "$result" | sed 's/.*name = //' | sed 's/\..*//'
            return
        fi
    fi

    echo ""
}

# Run a full mDNS scan and cache results
# Cache format: ip|mdns_name|timestamp
mdns_scan() {
    [ ! -d "/tmp" ] && return

    if command -v avahi-browse >/dev/null 2>&1; then
        avahi-browse -a -t -r -p 2>/dev/null | while IFS=';' read -r iface proto name type domain ip_port; do
            local ip=$(echo "$ip_port" | cut -d'/' -f1)
            local mdns_name=$(echo "$name" | sed 's/\.local$//')
            [ -n "$ip" ] && [ -n "$mdns_name" ] && echo "$ip|$mdns_name|$(date +%s)"
        done > "$MDNS_CACHE"
    fi
}

# Lookup mDNS cache for an IP
mdns_lookup() {
    local ip="$1"
    # Cache valid for 300 seconds (5 minutes)
    local now=$(date +%s)
    if [ -f "$MDNS_CACHE" ]; then
        local entry=$(grep "^$ip|" "$MDNS_CACHE" | tail -1)
        if [ -n "$entry" ]; then
            local ts=$(echo "$entry" | cut -d'|' -f3)
            if [ $((now - ts)) -lt 300 ]; then
                echo "$entry" | cut -d'|' -f2
                return
            fi
        fi
    fi

    # If no cache or expired, try live probe
    mdns_probe_ip "$ip"
}

# Infer vendor from mDNS name
infer_vendor_from_mdns() {
    local name="$1"
    local n=$(echo "$name" | tr 'A-Z' 'a-z')

    case "$n" in
        *iphone*|*ipad*|*macbook*|*imac*|*mac-pro*|*mac-mini*|*airplay*|*homepod*)
            echo "Apple"
            ;;
        *redmi*|*xiaomi*|*mi-*|*mico*|*yeelight*)
            echo "Xiaomi"
            ;;
        *samsung*|*galaxy*)
            echo "Samsung"
            ;;
        *huawei*|*honor*)
            echo "Huawei"
            ;;
        *chromecast*|*google-home*|*nest*)
            echo "Google"
            ;;
        *echo*|*kindle*|*fire-*)
            echo "Amazon"
            ;;
        *sonos*)
            echo "Sonos"
            ;;
        *hp-*|*hp_*|*deskjet*|*laserjet*|*officejet*)
            echo "HP"
            ;;
        *brother*)
            echo "Brother"
            ;;
        *epson*)
            echo "Epson"
            ;;
        *canon*)
            echo "Canon"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ============================================================
# UCI Persistence and dnsmasq Sync
# ============================================================

# Save discovered device to UCI config
save_device_to_uci() {
    local mac="$1"
    local ip="$2"
    local display_name="$3"
    local vendor="$4"
    local devtype="$5"

    [ -z "$mac" ] || [ -z "$ip" ] && return

    # Check dnsmasq by reading /etc/config/dhcp directly (no UCI lock)
    local current_dnsmasq_name=""
    local found_dhcp=""
    if [ -f /etc/config/dhcp ]; then
        local in_host=0 host_section=""
        while IFS= read -r line; do
            case "$line" in
                "config host"*)
                    # Check previous host section
                    if [ -n "$host_mac" ] && [ "$host_mac" = "$mac" ]; then
                        current_dnsmasq_name="$host_name"
                        found_dhcp="$host_section"
                        break
                    fi
                    host_mac="" host_name="" host_section=""
                    in_host=1
                    ;;
                option\ mac\ *)
                    host_mac=$(echo "$line" | sed 's/.*mac //;s/'"'"'//g')
                    ;;
                option\ name\ *)
                    host_name=$(echo "$line" | sed 's/.*name //;s/'"'"'//g')
                    ;;
                option\ ip\ *)
                    host_ip=$(echo "$line" | sed 's/.*ip //;s/'"'"'//g')
                    ;;
            esac
        done < /etc/config/dhcp
        # Check last section
        if [ -n "$host_mac" ] && [ "$host_mac" = "$mac" ] && [ -z "$found_dhcp" ]; then
            current_dnsmasq_name="$host_name"
            found_dhcp="$host_section"
        fi
    fi

    # Skip if dnsmasq already has the correct name
    if [ "$current_dnsmasq_name" = "$display_name" ]; then
        return
    fi

    # Use uci batch for atomic update (single lock acquisition)
    local uci_cmds=""
    local section=""

    # Find existing device section by scanning config file
    if [ -f /etc/config/devicemaster ]; then
        local in_dev=0
        while IFS= read -r line; do
            case "$line" in
                "config device"*)
                    if [ -n "$sec_mac" ] && [ "$sec_mac" = "$mac" ] && [ -n "$sec_ref" ]; then
                        section="$sec_ref"
                        break
                    fi
                    sec_mac="" sec_ref="" in_dev=1
                    ;;
                option\ mac\ *)
                    sec_mac=$(echo "$line" | sed 's/.*mac //;s/'"'"'//g')
                    ;;
            esac
        done < /etc/config/devicemaster
        if [ -n "$sec_mac" ] && [ "$sec_mac" = "$mac" ] && [ -z "$section" ]; then
            section="$sec_ref"
        fi
    fi

    if [ -z "$section" ]; then
        uci_cmds="uci add devicemaster device\n"
        section=$(uci add devicemaster device 2>/dev/null)
        [ -z "$section" ] && return
    fi

    # Batch all UCI operations
    uci set "devicemaster.$section.mac=$mac"
    uci set "devicemaster.$section.name=$display_name"
    [ -n "$vendor" ] && uci set "devicemaster.$section.vendor=$vendor"
    [ -n "$devtype" ] && uci set "devicemaster.$section.type=$devtype"
    uci set "devicemaster.$section.discovered=1"
    uci set "devicemaster.$section.discovered_at=$(date +%s)"
    uci commit devicemaster

    # Sync to dnsmasq (MAC-strong binding, IP-weak binding)
    sync_to_dnsmasq "$mac" "$ip" "$display_name"
}

# Sync device name to dnsmasq static lease
# MAC + hostname = strong binding (hostname follows MAC)
# MAC + IP = weak binding (IP updates when device gets new IP)
sync_to_dnsmasq() {
    local mac="$1"
    local ip="$2"
    local name="$3"

    [ -z "$mac" ] || [ -z "$ip" ] || [ -z "$name" ] && return

    # Sanitize hostname for dnsmasq: only allow a-z, A-Z, 0-9, -
    # dnsmasq rejects hostnames with other characters (e.g., Chinese)
    local safe_name=$(echo "$name" | sed 's/[^a-zA-Z0-9-]/-/g; s/^-//; s/-$//')
    # If name becomes empty (e.g., all Chinese chars), use IP suffix
    if [ -z "$safe_name" ]; then
        local ip_suffix=$(echo "$ip" | awk -F. '{print $4}')
        safe_name="device-${ip_suffix}"
    fi

    # Check for duplicate hostnames and add suffix if needed
    local base_name="$safe_name"
    local counter=1
    while true; do
        # Check if this name is already used by another MAC
        local dup_entry=$(uci show dhcp 2>/dev/null | grep "\.name='${safe_name}'" | grep -v "${mac}" | head -1)
        if [ -z "$dup_entry" ]; then
            break
        fi
        # Name exists, try with suffix
        counter=$((counter + 1))
        safe_name="${base_name}-${counter}"
        # Prevent infinite loop
        [ "$counter" -gt 100 ] && break
    done

    # Find existing entry by MAC (strong binding)
    local existing_section=""
    local found_entry=$(uci show dhcp 2>/dev/null | grep "\.mac='${mac}'" | head -1)
    if [ -n "$found_entry" ]; then
        existing_section=$(echo "$found_entry" | cut -d. -f2 | cut -d= -f1)
    fi

    if [ -n "$existing_section" ]; then
        # Update existing entry (IP weak binding - update when changed)
        uci set "dhcp.$existing_section.name=$safe_name"
        uci set "dhcp.$existing_section.ip=$ip"
    else
        # Create new entry
        local host_section=$(uci add dhcp host 2>/dev/null)
        [ -z "$host_section" ] && return
        uci set "dhcp.$host_section.mac=$mac"
        uci set "dhcp.$host_section.ip=$ip"
        uci set "dhcp.$host_section.name=$safe_name"
    fi

    uci commit dhcp

    # Reload dnsmasq to apply changes (only if config changed)
    /etc/init.d/dnsmasq reload 2>/dev/null || true
}

# ============================================================
# DHCP Fingerprinting (Option 55)
# ============================================================

# Extract DHCP Option 55 (Parameter Request List) from dnsmasq log
# This identifies the OS by the order of requested DHCP options
dhcp_fingerprint_lookup() {
    local mac="$1"

    # Check if dnsmasq logs DHCP requests with options
    if [ -f "/tmp/dnsmasq.log" ] || [ -f "/var/log/dnsmasq.log" ]; then
        local logfile="/tmp/dnsmasq.log"
        [ ! -f "$logfile" ] && logfile="/var/log/dnsmasq.log"

        # Look for DHCP request from this MAC with option 55
        local opt55=$(grep -i "$mac" "$logfile" 2>/dev/null | grep 'req-opt:' | tail -1 | sed 's/.*req-opt: *//' | tr -d ' ')

        if [ -n "$opt55" ]; then
            # Match against known fingerprints
            case "$opt55" in
                # iOS/macOS typical: 1,3,6,15,26,28,51,58,59,119,121
                *1,3,6,15,26,28,51*|*1,3,6,15,26,28,51,58,59,119,121*)
                    echo "Apple"
                    return
                    ;;
                # Android typical: 1,3,6,12,15,21,23,28,36,42,119,121
                *1,3,6,12,15,21,23,28,36,42*|*1,3,6,12,15,21,23,28,36,42,119,121*)
                    echo "Android"
                    return
                    ;;
                # Windows typical: 1,3,6,15,31,33,43,44,46,47,119,121,249,252
                *1,3,6,15,31,33,43,44*|*1,3,6,15,31,33,43,44,46,47,119,121,249,252*)
                    echo "Windows"
                    return
                    ;;
                # Linux typical: 1,3,6,12,15,17,28,42,119,121
                *1,3,6,12,15,17,28,42*|*1,3,6,12,15,17,28,42,119,121*)
                    echo "Linux"
                    return
                    ;;
            esac
        fi
    fi

    # Also check dnsmasq lease info for DHCP client class
    if [ -f "$DHCP_LEASES" ]; then
        # dnsmasq sometimes logs vendor class
        local vendor_class=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $5}')
        case "$vendor_class" in
            MSFT)
                echo "Windows"
                return
                ;;
            windows)
                echo "Windows"
                return
                ;;
            Apple)
                echo "Apple"
                return
                ;;
            MacOS)
                echo "Apple"
                return
                ;;
            android)
                echo "Android"
                return
                ;;
        esac
    fi

    echo ""
}

# ============================================================
# Hostname-based Inference
# ============================================================

infer_vendor_from_hostname() {
    local hostname="$1"
    local h=$(echo "$hostname" | tr 'A-Z' 'a-z')

    case "$h" in
        *redmi*|*mi-*|*mi_*|*xiaomi*|*mido*|*nitrogen*|*cepheus*|*raphael*|*davinci*|*vayu*|*begonia*)
            echo "Xiaomi"
            ;;
        *iphone*|*ipad*|*macbook*|*imac*|*mac-mini*)
            echo "Apple"
            ;;
        *samsung*|*galaxy*|*s20*|*s21*|*s22*|*s23*|*s24*|*s25*|*note*|*a5*|*a1*|*a2*|*a3*|*j7*|*j5*)
            echo "Samsung"
            ;;
        *huawei*|*honor*|*nova*|*mate*|*p40*|*p50*|*p60*)
            echo "Huawei"
            ;;
        *oppo*|*cph*|*rmx*|*a37*|*a57*|*a73*|*a93*|*find*|*reno*)
            echo "OPPO"
            ;;
        *vivo*|*v19*|*v20*|*v21*|*v23*|*v29*|*x60*|*x70*|*x80*|*x90*|*x100*)
            echo "vivo"
            ;;
        *oneplus*)
            echo "OnePlus"
            ;;
        *realme*)
            echo "Realme"
            ;;
        *pixel*|*nexus*)
            echo "Google"
            ;;
        *surface*|*lumia*|*windows*)
            echo "Microsoft"
            ;;
        *dell*|*latitude*|*inspiron*|*xps*|*precision*|*optiplex*)
            echo "Dell"
            ;;
        *lenovo*|*thinkpad*|*thinkcentre*|*ideapad*|*legion*)
            echo "Lenovo"
            ;;
        *hp*|*hp-*|*pavilion*|*omen*|*elitebook*|*probook*|*zbook*)
            echo "HP"
            ;;
        *asus*|*rog*|*tuf*|*zenbook*|*vivobook*)
            echo "ASUS"
            ;;
        *acer*|*aspire*|*predator*|*nitro*)
            echo "Acer"
            ;;
        *espressif*|*esp32*|*esp8266*)
            echo "Espressif"
            ;;
        *tuya*|*smart-life*)
            echo "Tuya"
            ;;
        *yeelight*)
            echo "Yeelight"
            ;;
        *midea*)
            echo "Midea"
            ;;
        *haier*|*u-home*)
            echo "Haier"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ============================================================
# Device Type Detection
# ============================================================

detect_device_type() {
    local mac="$1"
    local hostname="$2"
    local vendor="$3"

    # Case-insensitive vendor matching
    local v=$(echo "$vendor" | tr 'A-Z' 'a-z')
    case "$v" in
        *apple*|*samsung*|*xiaomi*|*huawei*|*oppo*|*vivo*|*oneplus*|*realme*|*google*|*android*|*nokia*|*motorola*|*sony*|*lg*|*htc*|*blackberry*|*zte*|*lenovo*|*asus*|*microsoft*)
            echo "phone"
            return
            ;;
        *dell*|*lenovo*|*hp*|*asus*|*acer*|*microsoft*|*intel*|*realtek*|*windows*)
            echo "pc"
            return
            ;;
        *espressif*|*tuya*|*broadlink*|*yeelight*|*midea*|*haier*|*brother*|*epson*|*canon*)
            echo "iot"
            return
            ;;
        *cisco*|*tp-link*|*netgear*|*ubiquiti*|*mikrotik*|*hiwifi*)
            echo "network"
            return
            ;;
    esac

    local h=$(echo "$hostname" | tr 'A-Z' 'a-z')
    case "$h" in
        *iphone*|*ipad*|*redmi*|*samsung*|*galaxy*|*huawei*|*honor*|*oppo*|*vivo*|*pixel*|*oneplus*|*realme*|*mate*|*nova*|*reno*|*find*|*nokia*|*lumia*|*windows-phone*|*motorola*|*xperia*)
            echo "phone"
            return
            ;;
        *desktop*|*laptop*|*pc*|*thinkpad*|*latitude*|*pavilion*|*xps*|*ideapad*|*macbook*|*imac*|*surface*|*legion*|*omen*|*rog*|*zenbook*|*vivobook*|*inspiron*|*aspire*|*predator*|*nitro*|*optiplex*|*elitebook*|*probook*|*zbook*|*precision*)
            echo "pc"
            return
            ;;
        *esp*|*tuya*|*yeelight*|*midea*|*haier*|*smart*|*plug*|*bulb*|*sensor*|*switch*|*camera*|*door*|*lock*|*thermostat*|*aircon*|*purifier*)
            echo "iot"
            return
            ;;
    esac

    echo "unknown"
}

# ============================================================
# Traffic-based Detection
# ============================================================

detect_type_by_traffic() {
    local mac="$1"
    local ip=$(grep -i "$mac" "$ARP_TABLE" 2>/dev/null | awk '{print $1}' | head -1)
    [ -z "$ip" ] && return

    local conntrack="/proc/net/nf_conntrack"
    [ ! -f "$conntrack" ] && return

    local ports=$(grep "src=$ip " "$conntrack" 2>/dev/null | grep 'dport=' | sed 's/.*dport=//' | awk '{print $1}' | sort -u)

    local has_phone_ports=0
    local has_pc_ports=0
    local has_iot_ports=0

    for port in $ports; do
        case "$port" in
            5228)
                has_phone_ports=1
                ;;
            554|8554|5060|5061|5555)
                has_phone_ports=1
                ;;
            1883|8883|5683|5684|49152|49153|6668|9999|8080|8443)
                has_iot_ports=1
                ;;
            3389|22|445|139|135|5900|5901)
                has_pc_ports=1
                ;;
        esac
    done

    if [ "$has_pc_ports" -eq 1 ] && [ "$has_phone_ports" -eq 0 ]; then
        echo "pc"
    elif [ "$has_iot_ports" -eq 1 ] && [ "$has_phone_ports" -eq 0 ] && [ "$has_pc_ports" -eq 0 ]; then
        echo "iot"
    elif [ "$has_phone_ports" -eq 1 ]; then
        echo "phone"
    fi
}

# ============================================================
# nlbwmon Traffic Analysis (if nlbwmon is installed)
# ============================================================

NLBWMON_CACHE="/tmp/devicemaster_nlbwmon_cache"
UCI_CACHE="/tmp/devicemaster_uci_cache"
UCI_CUSTOM_CACHE="/tmp/devicemaster_custom_cache"
MDNS_CACHE="/tmp/devicemaster_mdns_cache"

# Load nlbwmon data once and cache it to file
load_nlbwmon_data() {
    if [ ! -f "$NLBWMON_CACHE" ] || [ $(($(date +%s) - $(stat -c %Y "$NLBWMON_CACHE" 2>/dev/null || echo 0))) -gt 60 ]; then
        if [ -x /usr/libexec/nlbwmon-action ]; then
            /usr/libexec/nlbwmon-action download -g mac,layer7 -o -rx_bytes,-tx_bytes 2>/dev/null > "$NLBWMON_CACHE"
        else
            echo "" > "$NLBWMON_CACHE"
        fi
    fi
}

# Pre-build OUI cache for all known MACs
# Combines local OUI file + oui_lookup.sh cache + remote API queries for missing entries
_build_oui_cache() {
    local mode=$(uci get devicemaster.settings.oui_mode 2>/dev/null)
    mode="${mode:-remote}"

    # If local mode and local file exists, use it directly
    if [ "$mode" = "local" ] && [ -f "$OUI_DB" ]; then
        cp "$OUI_DB" "$OUI_CACHE"
        return
    fi

    # Start with local OUI file if available
    if [ -f "$OUI_DB" ]; then
        cp "$OUI_DB" "$OUI_CACHE"
    else
        > "$OUI_CACHE"
    fi

    # Merge oui_lookup.sh cache (if exists) - format: OUI|VENDOR|TIMESTAMP
    if [ -f "$OUI_LOOKUP_CACHE" ]; then
        awk -F'|' 'NF>=2 {print $1"|"$2}' "$OUI_LOOKUP_CACHE" >> "$OUI_CACHE"
    fi

    # In remote mode, query missing OUIs via API
    if [ "$mode" = "remote" ]; then
        # Collect all unique MAC prefixes from DHCP leases (field 2) and ARP table (field 4)
        # Extract OUI (first 6 chars of MAC without colons)
        local prefixes=$(awk '{mac=toupper($2); gsub(/:/, "", mac); print substr(mac,1,6)}' "$DHCP_LEASES" 2>/dev/null; \
            awk 'NR>1 {mac=toupper($4); gsub(/:/, "", mac); print substr(mac,1,6)}' "$ARP_TABLE" 2>/dev/null | grep -v "000000000000" | sort -u)

        local oui_lookup="/usr/libexec/devicemaster/oui_lookup.sh"
        for prefix in $prefixes; do
            # Skip if already in cache
            grep -q "^${prefix}|" "$OUI_CACHE" 2>/dev/null && continue
            # Query via API (uses oui_lookup.sh which handles caching)
            local vendor=$($oui_lookup lookup "$(echo "$prefix" | cut -c1-2):$(echo "$prefix" | cut -c3-4):$(echo "$prefix" | cut -c5-6):00:00:00" 2>/dev/null)
            if [ -n "$vendor" ] && [ "$vendor" != "Unknown" ]; then
                echo "${prefix}|${vendor}" >> "$OUI_CACHE"
            fi
        done
    fi
}

# Load UCI device data once (read config files directly to avoid UCI lock contention)
load_uci_data() {
    [ -f "$UCI_CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$UCI_CACHE" 2>/dev/null || echo 0))) -lt 60 ] && return
    awk '
    /^[[:space:]]*config device/ {
        if (in_device && mac != "") print mac","name","vendor","devtype","discovered_at","last_ip
        in_device=1; mac=""; name=""; vendor=""; devtype=""; discovered_at=""; last_ip=""
    }
    /^[[:space:]]*config / && !/^[[:space:]]*config device/ {
        in_device=0
    }
    in_device && /^[[:space:]]*option mac / {
        gsub(/'"'"'/, "", $0)
        mac = $NF
    }
    in_device && /^[[:space:]]*option name / {
        gsub(/'"'"'/, "", $0)
        sub(/^[[:space:]]*option name[[:space:]]+/, "", $0)
        name = $0
    }
    in_device && /^[[:space:]]*option vendor / {
        gsub(/'"'"'/, "", $0)
        sub(/^[[:space:]]*option vendor[[:space:]]+/, "", $0)
        vendor = $0
    }
    in_device && /^[[:space:]]*option type / {
        gsub(/'"'"'/, "", $0)
        sub(/^[[:space:]]*option type[[:space:]]+/, "", $0)
        devtype = $0
    }
    in_device && /^[[:space:]]*option discovered_at / {
        gsub(/'"'"'/, "", $0)
        discovered_at = $NF
    }
    in_device && /^[[:space:]]*option last_ip / {
        gsub(/'"'"'/, "", $0)
        last_ip = $NF
    }
    END {
        if (in_device && mac != "") print mac","name","vendor","devtype","discovered_at","last_ip
    }
    ' /etc/config/devicemaster | sort -u > "$UCI_CACHE"
}

# Load custom device fields (name, vendor, type, blocked, rate_limit, group, notes) from UCI
load_custom_data() {
    [ -f "$UCI_CUSTOM_CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$UCI_CUSTOM_CACHE" 2>/dev/null || echo 0))) -lt 60 ] && return
    
    # Use UCI to reliably get device data (handles interleaved config sections)
    > "$UCI_CUSTOM_CACHE"
    local idx=0
    local empty_count=0
    while [ $empty_count -lt 5 ]; do
        local mac=$(uci -q get "devicemaster.@device[$idx].mac" 2>/dev/null)
        if [ -n "$mac" ]; then
            local name=$(uci -q get "devicemaster.@device[$idx].name" 2>/dev/null)
            local vendor=$(uci -q get "devicemaster.@device[$idx].vendor" 2>/dev/null)
            local type=$(uci -q get "devicemaster.@device[$idx].type" 2>/dev/null)
            local blocked=$(uci -q get "devicemaster.@device[$idx].blocked" 2>/dev/null)
            local rate_limit=$(uci -q get "devicemaster.@device[$idx].rate_limit" 2>/dev/null)
            local group=$(uci -q get "devicemaster.@device[$idx].group" 2>/dev/null)
            local notes=$(uci -q get "devicemaster.@device[$idx].notes" 2>/dev/null)
            echo "$mac,$name,$vendor,$type,$blocked,$rate_limit,$group,$notes" >> "$UCI_CUSTOM_CACHE"
            empty_count=0
        else
            empty_count=$((empty_count + 1))
        fi
        idx=$((idx + 1))
    done
}

# Load mDNS data once
load_mdns_data() {
    [ -f "$MDNS_CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$MDNS_CACHE" 2>/dev/null || echo 0))) -lt 30 ] && return
    if [ -x /usr/bin/avahi-browse ]; then
        avahi-browse -a -t -p 2>/dev/null | grep "^=;" | \
            awk -F';' '{print $4","$7","$8}' | sort -u > "$MDNS_CACHE"
    else
        : > "$MDNS_CACHE"
    fi
}

# Detect vendor from nlbwmon layer7 protocol data
# nlbwmon output format: {"columns": [...], "data": [["proto",port,"mac",...,...,...,...,...,"layer7"]]}
detect_by_nlbwmon() {
    local mac="$1"
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')

    [ ! -f "$NLBWMON_CACHE" ] && return

    # Extract layer7 protocols for this MAC
    # Split by ']', grep for MAC, then extract last field
    # Use temp file to avoid subshell variable issue
    local tmpfile="/tmp/nlbw_proto_$$"
    tr ']' '\n' < "$NLBWMON_CACHE" 2>/dev/null | grep "$mac_lower" | while read -r line; do
        echo "$line" | tr ',' '\n' | tail -1 | tr -d '"'
    done | sort -u > "$tmpfile"

    local protocols=$(cat "$tmpfile" 2>/dev/null | tr '\n' ' ')
    rm -f "$tmpfile"

    [ -z "$protocols" ] && return

    local has_apple=0
    local has_google=0
    local has_microsoft=0
    local has_xmpp=0
    local has_imap=0

    # Check for specific protocols (protocols string is space-separated)
    case "$protocols" in
        *"Apple Push Service"*)
            has_apple=1
            ;;
    esac
    case "$protocols" in
        *"Google Cloud Messaging"*)
            has_google=1
            ;;
    esac
    case "$protocols" in
        *"Microsoft RDP"*)
            has_microsoft=1
            ;;
    esac
    case "$protocols" in
        *"XMPP"*)
            has_xmpp=1
            ;;
    esac
    case "$protocols" in
        *"IMAPS"*)
            has_imap=1
            ;;
    esac

    if [ "$has_apple" -eq 1 ]; then
        echo "Apple"
        return
    fi

    if [ "$has_google" -eq 1 ] && [ "$has_xmpp" -eq 1 ]; then
        echo "Samsung"
        return
    fi

    if [ "$has_microsoft" -eq 1 ]; then
        echo "Microsoft"
        return
    fi

    if [ "$has_imap" -eq 1 ] && [ "$has_google" -eq 1 ]; then
        echo "Android"
        return
    fi
}

# Detect device type from nlbwmon protocol distribution
detect_type_by_nlbwmon() {
    local mac="$1"
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')

    [ ! -f "$NLBWMON_CACHE" ] && return

    # Split by ']', grep for MAC, then extract last field
    local protocols=$(tr ']' '\n' < "$NLBWMON_CACHE" 2>/dev/null | grep "$mac_lower" | while read -r line; do
        echo "$line" | tr ',' '\n' | tail -1 | tr -d '"'
    done | sort -u | tr '\n' ' ')

    [ -z "$protocols" ] && return

    local has_rdp=0
    local has_push=0
    local has_imap=0

    for proto in $protocols; do
        case "$proto" in
            "Microsoft RDP")
                has_rdp=1
                ;;
            "Apple Push Service"|"Google Cloud Messaging")
                has_push=1
                ;;
            "IMAPS"|"IMAP")
                has_imap=1
                ;;
        esac
    done

    if [ "$has_rdp" -eq 1 ]; then
        echo "pc"
        return
    fi

    if [ "$has_push" -eq 1 ] || [ "$has_imap" -eq 1 ]; then
        echo "phone"
        return
    fi
}

# Get traffic stats for a device from nlbwmon
# nlbwmon format: ["protocol",port,"mac",conn,rx_bytes,tx_bytes,...,...,"name"]
get_nlbwmon_traffic() {
    local mac="$1"
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')

    [ ! -f "$NLBWMON_CACHE" ] && return

    # Split by ']', grep for MAC, then sum rx_bytes (field 6) and tx_bytes (field 8)
    # Fields: ,["proto",port,"mac",conn,rx_bytes,rx_pkts,tx_bytes,tx_pkts,"layer7"
    local rx_lines=$(tr ']' '\n' < "$NLBWMON_CACHE" 2>/dev/null | grep "$mac_lower" | cut -d',' -f6)
    local tx_lines=$(tr ']' '\n' < "$NLBWMON_CACHE" 2>/dev/null | grep "$mac_lower" | cut -d',' -f8)
    local rx=0
    local tx=0
    for val in $rx_lines; do
        rx=$((rx + val))
    done
    for val in $tx_lines; do
        tx=$((tx + val))
    done

    rx=${rx:-0}
    tx=${tx:-0}

    echo "$rx $tx"
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then
        printf "%.1f GB" $(echo "scale=1; $bytes/1073741824" | bc)
    elif [ $bytes -gt 1048576 ]; then
        printf "%.1f MB" $(echo "scale=1; $bytes/1048576" | bc)
    elif [ $bytes -gt 1024 ]; then
        printf "%.1f KB" $(echo "scale=1; $bytes/1024" | bc)
    else
        echo "${bytes} B"
    fi
}

# ============================================================
# Online Check
# ============================================================

is_online() {
    local mac="$1"
    # Check ARP table: any non-STALE (non-0x0) entry on LAN subnet counts as online
    # Exclude 169.254.x.x (APIPA/link-local) addresses
    awk -v mac="$mac" '
    NR>1 && tolower($4) == tolower(mac) {
        # Skip APIPA link-local addresses
        if ($1 ~ /^169\.254\./) next
        # $3 is flags: 0x0=STALE(offline), 0x2=REACHABLE, 0x6=REACHABLE+ROUTER
        if ($3 != "0x0") { print "1"; exit }
    }
    END { print "0" }
    ' "$ARP_TABLE" 2>/dev/null | grep -q "1"
}

# ============================================================
# Main: Get All Devices (Fast Mode - no mDNS, no nlbwmon)
# Single awk pass over all data sources for maximum speed
# ============================================================

# Fast update: only update online status from existing cache
# Does NOT re-query OUI, vendor, type, or hostname
# 优化: 使用 awk 一次性处理，避免逐行 sed -i
get_all_devices_fast() {
    local cache_file="/tmp/devicemaster_device_cache"
    
    # If no existing cache, fall back to full refresh
    if [ ! -f "$cache_file" ]; then
        get_all_devices
        return
    fi
    
    # Build ARP online MAC list (转为正则格式)
    local online_macs
    online_macs=$(awk 'NR>1 && $4!="00:00:00:00:00:00" && $3!="0x0" {print toupper($4)}' "$ARP_TABLE" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    
    # 使用 awk 一次性处理整个文件，避免逐行 sed -i
    awk -v online_pattern="$online_macs" '
    BEGIN { split(online_pattern, online_arr, "|"); for(i in online_arr) online[online_arr[i]] = 1 }
    /"mac":/ {
        match($0, /"mac": "([^"]+)"/, m)
        cur_mac = m[1]
    }
    /"online":/ {
        if (cur_mac in online) {
            gsub(/"online": (true|false)/, "\"online\": true")
        } else {
            gsub(/"online": (true|false)/, "\"online\": false")
        }
        cur_mac = ""
    }
    { print }
    ' "$cache_file"
}

# Sync hostnames to UCI: DHCP changes + auto-naming for unknown devices
# 优化: 批量 UCI commit，减少磁盘写入
sync_hostname_to_uci() {
    [ ! -f "$DHCP_LEASES" ] && [ ! -f /etc/config/devicemaster ] && return

    local modified=0  # 标记是否有修改

    # 预加载 MAC -> section 映射，避免重复 UCI 查询
    local mac_to_section="/tmp/dm_mac_section_map"
    > "$mac_to_section"
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local uci_mac=$(uci -q get "devicemaster.@device[$idx].mac" 2>/dev/null)
        if [ -n "$uci_mac" ]; then
            echo "${uci_mac} $idx" >> "$mac_to_section"
        fi
        idx=$((idx + 1))
    done

    # 1. Sync DHCP hostname changes and update last_ip
    if [ -f "$DHCP_LEASES" ]; then
        while IFS=' ' read -r ts mac ip hostname; do
            [ -z "$mac" ] && continue
            hostname=$(echo "$hostname" | awk '{print $1}')

            # 从预加载映射中查找 section
            local section=$(grep "^${mac} " "$mac_to_section" 2>/dev/null | awk '{print $2}')
            [ -z "$section" ] && continue

            # Update last_ip if device has IP
            if [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ]; then
                local current_last_ip=$(uci -q get devicemaster.@device[$section].last_ip 2>/dev/null)
                if [ "$current_last_ip" != "$ip" ]; then
                    uci set "devicemaster.@device[$section].last_ip=$ip"
                    modified=1
                fi
            fi

            # Sync hostname if valid and different
            [ -z "$hostname" ] || [ "$hostname" = "*" ] || [ "$hostname" = "-" ] && continue
            local uci_name=$(uci -q get devicemaster.@device[$section].name 2>/dev/null)
            [ -z "$uci_name" ] && continue

            if [ "$uci_name" != "$hostname" ]; then
                uci set "devicemaster.@device[$section].name=$hostname"
                modified=1
            fi
        done < "$DHCP_LEASES"
    fi

    # 2. Auto-name devices with unknown/empty hostname in UCI
    if [ -f /etc/config/devicemaster ]; then
        local oui_lookup="/usr/libexec/devicemaster/oui_lookup.sh"
        while IFS= read -r line; do
            local mac=$(echo "$line" | cut -d',' -f1)
            local name=$(echo "$line" | cut -d',' -f2)
            local vendor=$(echo "$line" | cut -d',' -f3)
            local devtype=$(echo "$line" | cut -d',' -f4)

            # Skip if already has a name
            [ -n "$name" ] && continue
            # Skip if no vendor or type
            [ -z "$vendor" ] || [ "$devtype" = "unknown" ] && continue

            # Query vendor if empty
            if [ -z "$vendor" ]; then
                vendor=$($oui_lookup lookup "$mac" 2>/dev/null)
                [ "$vendor" = "Unknown" ] && continue
            fi

            # Generate name: Vendor-type
            local short_vendor=$(echo "$vendor" | sed 's/,.*//; s/ Co\..*//; s/ Corporation.*//; s/ Inc\..*//; s/ Ltd\..*//; s/ LLC.*//')
            local auto_name="${short_vendor}-${devtype}"
            auto_name=$(echo "$auto_name" | sed 's/[^a-zA-Z0-9-]/-/g; s/-+/-/g; s/^-//; s/-$//')

            # Check for name conflicts in DHCP leases + UCI
            local base_name="$auto_name"
            local n=1
            while true; do
                [ $n -gt 1 ] && auto_name="${base_name}-${n}"
                # Check DHCP
                if grep -q "$(echo "$auto_name" | tr 'A-Z' 'a-z')" "$DHCP_LEASES" 2>/dev/null; then
                    n=$((n + 1))
                    continue
                fi
                # Check UCI
                if uci show devicemaster 2>/dev/null | grep -q "\.name='${auto_name}'"; then
                    n=$((n + 1))
                    continue
                fi
                break
            done

            # Save to UCI
            local section=$(grep "^${mac} " "$mac_to_section" 2>/dev/null | awk '{print $2}')
            [ -z "$section" ] && continue

            uci set "devicemaster.@device[$section].name=$auto_name"
            uci set "devicemaster.@device[$section].vendor=$vendor"
            uci set "devicemaster.@device[$section].type=$devtype"
            uci set "devicemaster.@device[$section].discovered=1"
            uci set "devicemaster.@device[$section].discovered_at=$(date +%s)"
            modified=1

            # Also sync to dnsmasq so OpenWrt shows the hostname in DHCP list
            local dev_ip=$(grep -i "^[^ ]* $mac " /tmp/dhcp.leases 2>/dev/null | awk '{print $3}')
            if [ -n "$dev_ip" ]; then
                sync_to_dnsmasq "$mac" "$dev_ip" "$auto_name" 2>/dev/null || true
            fi
        done < "$UCI_CACHE"
    fi

    # 3. Update last_ip from ARP table (for devices without DHCP lease)
    if [ -f "$ARP_TABLE" ]; then
        awk 'NR>1 && $4!="00:00:00:00:00:00" {print $4, $1}' "$ARP_TABLE" | while read mac ip; do
            [ -z "$mac" ] || [ -z "$ip" ] && continue
            [ "$ip" = "0.0.0.0" ] && continue

            local section=$(grep "^${mac} " "$mac_to_section" 2>/dev/null | awk '{print $2}')
            [ -z "$section" ] && continue

            local current_last_ip=$(uci -q get devicemaster.@device[$section].last_ip 2>/dev/null)
            if [ "$current_last_ip" != "$ip" ]; then
                uci set "devicemaster.@device[$section].last_ip=$ip"
                modified=1
            fi
        done
    fi

    # 批量 commit：只在有修改时执行一次
    if [ "$modified" = "1" ]; then
        uci -q commit devicemaster 2>/dev/null
    fi

    rm -f "$mac_to_section"
}

# ============================================================
# Main: Get All Devices
# ============================================================

get_all_devices() {
    local first=1

    echo '{"devices": ['

    # Pre-load data once for subshell access
    load_nlbwmon_data
    load_uci_data
    load_custom_data
    load_mdns_data

    # Get unique devices: prefer DHCP lease IP over ARP IP
    # Use awk to deduplicate by MAC, keeping first occurrence (DHCP has priority)
    {
        get_dhcp_leases
        get_arp_entries
    } | awk -F',' '
    {
        mac = tolower($2)
        ip = $1
        # Skip invalid entries
        if (mac == "" || mac == "00:00:00:00:00:00") next
        if (mac ~ /^0x/) next
        # Skip APIPA addresses
        if (ip ~ /^169\.254\./) next
        # First occurrence wins (DHCP comes first)
        if (!(mac in seen)) {
            seen[mac] = ip
        }
    }
    END {
        for (mac in seen) print mac "|" seen[mac]
    }
    ' | while IFS='|' read -r mac ip; do
        [ -z "$mac" ] && continue

        local hostname=""
        local vendor=""
        local devtype=""
        local online="false"
        local randomized="false"
        is_online "$mac" && online="true"
        is_randomized_mac "$mac" && randomized="true"

        # Get hostname from DHCP leases
        hostname=$(grep "$mac" "$DHCP_LEASES" 2>/dev/null | awk '{print $4}')
        [ -z "$hostname" ] || [ "$hostname" = "*" ] && hostname="unknown"

        # --- Identification Priority Chain ---

        # Priority 0: User manual annotation from UCI config (highest priority)
        local uci_name=""
        local uci_vendor=""
        local uci_type=""
        if [ -f "$UCI_CACHE" ]; then
            local uci_line=$(grep -i "^$mac," "$UCI_CACHE" 2>/dev/null | head -1)
            if [ -n "$uci_line" ]; then
                uci_name=$(echo "$uci_line" | cut -d',' -f2)
                uci_vendor=$(echo "$uci_line" | cut -d',' -f3)
                uci_type=$(echo "$uci_line" | cut -d',' -f4)
                [ -n "$uci_vendor" ] && vendor="$uci_vendor"
                [ -n "$uci_type" ] && devtype="$uci_type"
                [ -n "$uci_name" ] && [ "$hostname" = "unknown" ] && hostname="$uci_name"
            fi
        fi

        # Priority 1: OUI database lookup
        if [ -z "$vendor" ]; then
            vendor=$(lookup_oui "$mac")
        fi

        # Priority 2: Hostname pattern matching
        if [ -z "$vendor" ]; then
            vendor=$(infer_vendor_from_hostname "$hostname")
        fi

        # Priority 3: mDNS/Bonjour probe (especially for Apple devices)
        local mdns_name=""
        if [ -z "$vendor" ] && [ "$online" = "true" ] && [ -n "$ip" ]; then
            # Use pre-loaded mDNS cache file
            if [ -f "$MDNS_CACHE" ]; then
                mdns_name=$(grep ",$ip," "$MDNS_CACHE" 2>/dev/null | cut -d',' -f1 | head -1)
            fi
            # Fallback to direct lookup if not in cache
            if [ -z "$mdns_name" ]; then
                mdns_name=$(mdns_lookup "$ip")
            fi
            if [ -n "$mdns_name" ]; then
                # Update hostname if we got a better one from mDNS
                if [ "$hostname" = "unknown" ]; then
                    hostname="$mdns_name"
                fi
                vendor=$(infer_vendor_from_mdns "$mdns_name")
            fi
        fi

        # Priority 4: DHCP fingerprinting
        if [ -z "$vendor" ]; then
            local dhcp_vendor=$(dhcp_fingerprint_lookup "$mac")
            [ -n "$dhcp_vendor" ] && vendor="$dhcp_vendor"
        fi

        # Priority 4.5: nlbwmon layer7 protocol analysis (if installed)
        if [ -z "$vendor" ] && [ -x /usr/libexec/nlbwmon-action ]; then
            local nlbw_vendor=$(detect_by_nlbwmon "$mac")
            [ -n "$nlbw_vendor" ] && vendor="$nlbw_vendor"
        fi

        # Priority 5: If randomized MAC and still unknown, mark as "LAA Device"
        if [ -z "$vendor" ] && [ "$randomized" = "true" ]; then
            vendor="LAA Device"
        fi

        # Priority 6: If still unknown but has OUI, show OUI vendor
        if [ -z "$vendor" ] || [ "$vendor" = "Unknown" ]; then
            local oui_vendor=$(lookup_oui "$mac")
            [ -n "$oui_vendor" ] && vendor="${oui_vendor}"
        fi

        # Priority 7: Last resort - show as Generic Device
        if [ -z "$vendor" ] || [ "$vendor" = "Unknown" ]; then
            vendor="Generic Device"
        fi

        # --- Device Type Detection ---
        # Use UCI type if set, otherwise auto-detect
        if [ -z "$devtype" ]; then
            devtype=$(detect_device_type "$mac" "$hostname" "$vendor")
        fi

        # Fallback: traffic analysis for online unknown devices
        if [ "$devtype" = "unknown" ] && [ "$online" = "true" ]; then
            local traffic_type=$(detect_type_by_traffic "$mac")
            [ -n "$traffic_type" ] && devtype="$traffic_type"
        fi

        # Fallback: nlbwmon protocol-based type detection
        if [ "$devtype" = "unknown" ] && [ -x /usr/libexec/nlbwmon-action ]; then
            local nlbw_type=$(detect_type_by_nlbwmon "$mac")
            [ -n "$nlbw_type" ] && devtype="$nlbw_type"
        fi

        # Get traffic stats from nlbwmon
        local traffic_rx=0
        local traffic_tx=0
        if [ -f "$NLBWMON_CACHE" ]; then
            local traffic=$(get_nlbwmon_traffic "$mac")
            traffic_rx=$(echo "$traffic" | awk '{print $1}')
            traffic_tx=$(echo "$traffic" | awk '{print $2}')
            traffic_rx=${traffic_rx:-0}
            traffic_tx=${traffic_tx:-0}
        fi

        # --- Auto-save discovered device info to UCI ---
        # Generate display name: custom_name > mDNS/hostname > vendor+type > vendor > "Device"
        # IMPORTANT: dnsmasq does not allow spaces in hostnames, replace with hyphens
        local display_name=""
        if [ -n "$uci_name" ]; then
            display_name="$uci_name"
        elif [ -n "$mdns_name" ]; then
            display_name="$mdns_name"
        elif [ "$hostname" != "unknown" ] && [ "$hostname" != "*" ] && [ -n "$hostname" ]; then
            display_name="$hostname"
        elif [ -n "$vendor" ] && [ "$vendor" != "Generic Device" ] && [ "$vendor" != "LAA Device" ]; then
            if [ -n "$devtype" ] && [ "$devtype" != "unknown" ]; then
                display_name="${vendor}-${devtype}"
            else
                display_name="$vendor"
            fi
        fi

        # Sanitize: replace spaces with hyphens for dnsmasq compatibility
        display_name=$(echo "$display_name" | sed 's/ /-/g; s/[^a-zA-Z0-9._-]//g')

        # Queue device for async save (don't block the list command)
        # Save to UCI and sync to dnsmasq if:
        # 1. We have a good display name
        # 2. The original DHCP hostname was empty/unknown (needs fixing)
        if [ -n "$display_name" ]; then
            local dhcp_hostname=$(grep "$mac" "$DHCP_LEASES" 2>/dev/null | awk '{print $4}')
            [ -z "$dhcp_hostname" ] || [ "$dhcp_hostname" = "*" ] && dhcp_hostname="unknown"
        fi

        # Get custom fields from UCI cache (format: mac,name,vendor,type,blocked,rate_limit,group,notes)
        local custom_name="" blocked="false" rate_limit="" group="" notes=""
        if [ -f "$UCI_CUSTOM_CACHE" ]; then
            local custom_line=$(grep -i "^$mac," "$UCI_CUSTOM_CACHE" 2>/dev/null | head -1)
            if [ -n "$custom_line" ]; then
                custom_name=$(echo "$custom_line" | cut -d',' -f2)
                # f[3]=vendor, f[4]=type (not used here)
                blocked=$(echo "$custom_line" | cut -d',' -f5)
                rate_limit=$(echo "$custom_line" | cut -d',' -f6)
                group=$(echo "$custom_line" | cut -d',' -f7)
                notes=$(echo "$custom_line" | cut -d',' -f8)
            fi
        fi

        [ -z "$custom_name" ] && custom_name="null"
        [ -z "$rate_limit" ] && rate_limit="null"
        [ -z "$group" ] && group="null"
        [ -z "$notes" ] && notes="null"
        [ "$blocked" != "1" ] && blocked="false"

        # Add quotes around non-null string values for valid JSON
        [ "$custom_name" != "null" ] && custom_name="\"$custom_name\""
        [ "$rate_limit" != "null" ] && rate_limit="\"$rate_limit\""
        [ "$group" != "null" ] && group="\"$group\""
        [ "$notes" != "null" ] && notes="\"$notes\""

        # Determine if device is controllable (LAN side only)
        local is_controllable="false"
        local lan_prefix=$(ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."}')
        case "$ip" in
            ${lan_prefix}*) is_controllable="true" ;;
        esac

        [ $first -eq 0 ] && echo ','
        first=0

        echo "    {\"mac\": \"$mac\", \"ip\": \"$ip\", \"hostname\": \"$hostname\", \"vendor\": \"$vendor\", \"type\": \"$devtype\", \"online\": $online, \"randomized\": $randomized, \"is_controllable\": $is_controllable, \"traffic_rx\": $traffic_rx, \"traffic_tx\": $traffic_tx, \"custom_name\": $custom_name, \"blocked\": $blocked, \"rate_limit\": $rate_limit, \"group\": $group, \"notes\": $notes}"
    done

    echo ']}'

    # Save queue will be processed by cron or devicemasterd
}

# ============================================================
# CLI Entry Point
# ============================================================

# Only run CLI if executed directly (not sourced)
if [ "${0##*/}" = "device_collector.sh" ]; then
case "$1" in
    list)
        # Return cache immediately (0ms) — maintained by device_monitor.sh
        CACHE_FILE="/tmp/devicemaster_device_cache"
        if [ -f "$CACHE_FILE" ]; then
            cat "$CACHE_FILE"
        else
            # Fallback: use fast mode (atomic write with lock to prevent concurrent issues)
            LOCK_FILE="/tmp/devicemaster_list.lock"
            if mkdir "$LOCK_FILE" 2>/dev/null; then
                trap 'rmdir "$LOCK_FILE" 2>/dev/null' EXIT
                # Double-check after acquiring lock
                if [ -f "$CACHE_FILE" ]; then
                    cat "$CACHE_FILE"
                else
                    get_all_devices_fast > "$CACHE_FILE.tmp" 2>/dev/null
                    mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null
                    cat "$CACHE_FILE" 2>/dev/null
                fi
                rmdir "$LOCK_FILE" 2>/dev/null
            else
                # Another process is generating, wait briefly and read cache
                sleep 1
                if [ -f "$CACHE_FILE" ]; then
                    cat "$CACHE_FILE"
                else
                    # Last resort: output minimal JSON
                    echo '{"devices": []}'
                fi
            fi
        fi
        ;;
    fast)
        # Fast refresh: only update online status from ARP (~10ms)
        # Does NOT re-query OUI, vendor, type, hostname
        get_all_devices_fast
        ;;
    sync)
        # Sync DHCP hostnames and last_ip to UCI (called by device_monitor deep refresh)
        sync_hostname_to_uci
        ;;
    refresh)
        # Force deep refresh and update cache
        CACHE_FILE="/tmp/devicemaster_device_cache"
        get_all_devices > "$CACHE_FILE"
        cat "$CACHE_FILE"
        ;;
    lookup)
        lookup_oui "$2"
        ;;
    type)
        detect_device_type "$2" "" "$(lookup_oui "$2")"
        ;;
    online)
        is_online "$2" && echo "true" || echo "false"
        ;;
    mdns)
        # Run mDNS scan and show results
        mdns_scan
        if [ -f "$MDNS_CACHE" ]; then
            cat "$MDNS_CACHE"
        else
            echo "No mDNS results (avahi-browse not installed)"
        fi
        ;;
    mdns-probe)
        # Probe specific IP
        mdns_probe_ip "$2"
        ;;
    fingerprint)
        # Show DHCP fingerprint for a MAC
        dhcp_fingerprint_lookup "$2"
        ;;
    *)
        echo "Usage: $0 {list|lookup <mac>|type <mac>|online <mac>|mdns|mdns-probe <ip>|fingerprint <mac>}"
        exit 1
        ;;
esac
fi
