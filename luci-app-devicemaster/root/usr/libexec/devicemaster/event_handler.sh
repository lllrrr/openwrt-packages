#!/bin/sh
# DeviceMaster Event Handler (v2 - Full 7-Level Identification)
# Called by dnsmasq via --dhcp-script on lease changes
# Environment variables set by dnsmasq:
#   $1 = action (add|del|old)

# Ensure full PATH - dnsmasq jail may have limited PATH
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
#   $2 = MAC address
#   $3 = IP address (empty on del)
#   $4 = hostname (may be *)
#
# 7-Level Identification Chain:
#   1. Local OUI database
#   2. Remote OUI API (via oui_lookup.sh)
#   3. mDNS probe
#   4. DHCP hostname inference
#   5. DHCP fingerprint (Option 55) analysis
#   6. nlbwmon protocol analysis
#   7. Traffic pattern analysis (conntrack ports)

OUI_DB="/usr/share/devicemaster/oui.txt"
OUI_APPEND="/usr/share/devicemaster/oui_append.txt"
OUI_LOOKUP="/usr/libexec/devicemaster/oui_lookup.sh"
COLLECTOR="/usr/libexec/devicemaster/device_collector.sh"
ARP_TABLE="/proc/net/arp"
DHCP_LEASES="/tmp/dhcp.leases"
NLBWMON_CACHE="/tmp/devicemaster_nlbwmon_cache"
MDNS_CACHE="/tmp/devicemaster_mdns_cache"

# ============================================================
# Mesh Node Detection
# ============================================================

# Check if this device is a mesh child node (not the main router)
# Mesh child nodes should not modify dhcp config
is_mesh_child_node() {
    # Check if wpad/wpad-mesh is running and this is a mesh station
    local mesh_mode=$(uci -q get wireless.mesh0 2>/dev/null || uci -q get wireless.mesh0_0 2>/dev/null)
    local dhcp_enabled=$(uci -q get dhcp.lan.ignore 2>/dev/null)
    
    # If mesh interface exists and dhcp is disabled (common in mesh child nodes), skip dhcp modifications
    if [ -n "$mesh_mode" ] && [ "$dhcp_enabled" = "1" ]; then
        return 0
    fi
    return 1
}

# Check if this device is the mesh main router (has DHCP server enabled)
# Only main router should modify dhcp config
is_mesh_main_router() {
    # Emergency override: if force_dhcp_sync flag exists, always allow
    if [ -f "/tmp/devicemaster_force_dhcp_sync" ]; then
        log_msg "Emergency override: force_dhcp_sync flag detected, allowing dhcp sync"
        return 0
    fi
    
    # Must have dhcp server enabled on lan interface
    local dhcp_ignore=$(uci -q get dhcp.lan.ignore 2>/dev/null)
    
    # dhcp_ignore should be 0 or empty (default is to serve dhcp)
    if [ "$dhcp_ignore" = "1" ]; then
        log_msg "DHCP server disabled (dhcp.lan.ignore=1), skipping dhcp sync"
        return 1
    fi
    
    # Must have dhcp range configured
    local dhcp_start=$(uci -q get dhcp.lan.start 2>/dev/null)
    local dhcp_limit=$(uci -q get dhcp.lan.limit 2>/dev/null)
    
    if [ -z "$dhcp_start" ] || [ -z "$dhcp_limit" ]; then
        log_msg "DHCP range not configured (start=$dhcp_start, limit=$dhcp_limit), skipping dhcp sync"
        return 1
    fi
    
    # Must be able to read /tmp/dhcp.leases (has active dhcp server)
    if [ ! -f "/tmp/dhcp.leases" ]; then
        log_msg "No dhcp.leases file found, skipping dhcp sync"
        return 1
    fi
    
    return 0
}

log_msg() {
    logger -t devicemaster-event "$1"
}

# ============================================================
# Level 1: Local OUI database lookup
# ============================================================
lookup_oui_local() {
    local mac="$1"
    local oui=$(echo "$mac" | tr -d ':' | cut -c1-6 | tr 'a-f' 'A-F')

    if [ -f "$OUI_DB" ]; then
        local vendor=$(grep "^${oui}" "$OUI_DB" | cut -d'|' -f2 | head -1)
        if [ -n "$vendor" ]; then
            echo "$vendor" | sed 's/ Co\..*$//'
            return
        fi
    fi

    if [ -f "$OUI_APPEND" ]; then
        local vendor=$(grep -i "$(echo "$mac" | cut -c1-8)" "$OUI_APPEND" | head -1 | awk -F'\t' '{print $2}')
        if [ -n "$vendor" ]; then
            echo "$vendor"
            return
        fi
    fi

    echo ""
}

# ============================================================
# Level 2: Remote OUI API (via oui_lookup.sh module)
# ============================================================
lookup_oui_remote() {
    local mac="$1"
    if [ -x "$OUI_LOOKUP" ]; then
        local vendor=$($OUI_LOOKUP lookup "$mac" 2>/dev/null)
        if [ -n "$vendor" ] && [ "$vendor" != "Unknown" ] && [ "$vendor" != "LAA" ]; then
            echo "$vendor" | sed 's/ Co\..*$//'
            return
        fi
    fi
    echo ""
}

# ============================================================
# Level 3: mDNS probe
# ============================================================
mdns_probe_ip() {
    local ip="$1"
    local result=""

    # Priority 1: avahi-resolve returns clean hostname (e.g. "iPad-pro-M4.local")
    # avahi-browse returns raw mDNS name with escape codes (e.g. "iPad\032pro\032M4")
    if command -v avahi-resolve >/dev/null 2>&1; then
        result=$(avahi-resolve-host-name -a "$ip" 2>/dev/null | awk '{print $2}')
        if [ -n "$result" ]; then
            echo "$result" | sed 's/\.local$//'
            return
        fi
    fi

    # Priority 2: avahi-browse (fallback, may contain escape codes)
    if command -v avahi-browse >/dev/null 2>&1; then
        result=$(avahi-browse -a -t -r -p 2>/dev/null | grep -i "$ip" | head -1)
        if [ -n "$result" ]; then
            echo "$result" | awk -F';' '{print $4}' | sed 's/\.local$//'
            return
        fi
    fi

    # Priority 3: DNS reverse lookup (fallback)
    if command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup "$ip" 2>/dev/null | grep "name = " | head -1)
        if [ -n "$result" ]; then
            echo "$result" | sed 's/.*name = //' | sed 's/\..*//'
            return
        fi
    fi

    echo ""
}

infer_vendor_from_mdns() {
    local name="$1"
    local n=$(echo "$name" | tr 'A-Z' 'a-z')
    case "$n" in
        *iphone*|*ipad*|*macbook*|*imac*|*mac-pro*|*mac-mini*|*airplay*|*homepod*) echo "Apple" ;;
        *redmi*|*xiaomi*|*mi-*|*mico*|*yeelight*) echo "Xiaomi" ;;
        *samsung*|*galaxy*) echo "Samsung" ;;
        *huawei*|*honor*) echo "Huawei" ;;
        *chromecast*|*google-home*|*nest*) echo "Google" ;;
        *echo*|*kindle*|*fire-*) echo "Amazon" ;;
        *sonos*) echo "Sonos" ;;
        *hp-*|*hp_*|*deskjet*|*laserjet*|*officejet*) echo "HP" ;;
        *brother*) echo "Brother" ;;
        *epson*) echo "Epson" ;;
        *canon*) echo "Canon" ;;
        *) echo "" ;;
    esac
}

# ============================================================
# Level 4: DHCP hostname inference (with structured parsing)
# Strategy:
#   1. Structured parsing: extract vendor prefix, region, model
#      e.g. "H-de-S20" -> prefix=H(Honor), region=de, model=S20
#           "cph-nx1"  -> prefix=cph(OPPO), model=nx1
#   2. Full keyword fallback: match known brand words
# ============================================================
# Helper: vendor candidate collection (used by infer_vendor_from_hostname)
# Tracks best match by length (longer = more specific = higher confidence)
_DM_BEST_VENDOR=""
_DM_BEST_LEN=0
_dm_try_vendor() {
    local vendor="$1"
    local match_len="$2"
    if [ -n "$vendor" ] && [ "$match_len" -gt "$_DM_BEST_LEN" ]; then
        _DM_BEST_VENDOR="$vendor"
        _DM_BEST_LEN="$match_len"
    fi
}

infer_vendor_from_hostname() {
    local hostname="$1"
    local h=$(echo "$hostname" | tr 'A-Z' 'a-z')

    # Reset candidate state
    _DM_BEST_VENDOR=""
    _DM_BEST_LEN=0

    # --- Stage 1: Structured prefix parsing ---
    # Honor/Huawei: H-<region>-<model>
    case "$h" in
        h-*)
            local model=$(echo "$h" | sed 's/^h-[a-z]*-//')
            if [ -n "$model" ] && [ "$model" != "$h" ]; then
                _dm_try_vendor "Honor" 1  # prefix "h" is only 1 char
            fi
            ;;
    esac

    # OPPO: cph-<model> or rmx-<model>
    case "$h" in cph-*|rmx-*) _dm_try_vendor "OPPO" 3 ;; esac

    # vivo: v<numbers>
    case "$h" in v[0-9][0-9][0-9][0-9]*|v[0-9][0-9][0-9]*) _dm_try_vendor "vivo" 1 ;; esac

    # Realme: rmx-<model>
    case "$h" in rmx-*) _dm_try_vendor "Realme" 3 ;; esac

    # Xiaomi codenames
    case "$h" in
        mido|nitrogen|cepheus|raphael|davinci|vayu|begonia|nabu|alioth|surya|merlin|lancelot|monet|rosemary|joyeuse|biloba|citrus|olive|oliva|pipa|fog|dandelion|evergo|cannon|lisa|munch|stone|marble)
            _dm_try_vendor "Xiaomi" ${#h}
            ;;
    esac

    # --- Stage 2: Full keyword matching ---
    # Samsung models (high specificity)
    case "$h" in
        *s20*|*s21*|*s22*|*s23*|*s24*|*s25*)
            _dm_try_vendor "Samsung" 3 ;;
        *note10*|*note20*|*note21*)
            _dm_try_vendor "Samsung" 5 ;;
        *galaxy*a*|*sm-a*|*samsung*a*|*samsung*a[0-9]*|*galaxy*a[0-9]*|*sm-a[0-9]*)
            _dm_try_vendor "Samsung" 2 ;;
        *samsung*|*galaxy*)
            _dm_try_vendor "Samsung" 7 ;;
        *galaxy*j*|*sm-j*|*samsung*j*|*j[0-9][0-9]-galaxy|*j[0-9][0-9]-samsung)
            _dm_try_vendor "Samsung" 2 ;;
    esac

    # Huawei models
    case "$h" in
        *mate[0-9]*|*mate-[0-9]*)
            _dm_try_vendor "Huawei" 4 ;;
        *huawei*p*|*honor*p*|*p[0-9][0-9]*|*p[0-9][0-9]-*)
            _dm_try_vendor "Huawei" 2 ;;
        *nova[0-9]*)
            _dm_try_vendor "Huawei" 4 ;;
        *huawei*|*honor*)
            _dm_try_vendor "Huawei" 6 ;;
        *enjoy[0-9]*)
            _dm_try_vendor "Huawei" 5 ;;
    esac

    # Apple models
    case "$h" in
        *iphone*|*ipad*|*macbook*|*imac*|*mac-mini*)
            _dm_try_vendor "Apple" 6 ;;
    esac

    # Xiaomi
    case "$h" in
        *redmi*|*mi-*|*mi_*|*xiaomi*)
            _dm_try_vendor "Xiaomi" 5 ;;
    esac

    # OPPO
    case "$h" in
        *oppo*|*find*|*reno*|*a[0-9][0-9][0-9]*)
            _dm_try_vendor "OPPO" 4 ;;
    esac

    # vivo
    case "$h" in
        *vivo*|*x[0-9][0-9]*|*v[0-9][0-9]*)
            _dm_try_vendor "vivo" 4 ;;
    esac

    # Others
    case "$h" in
        *oneplus*) _dm_try_vendor "OnePlus" 7 ;;
        *realme*)  _dm_try_vendor "Realme" 6 ;;
        *pixel*|*nexus*) _dm_try_vendor "Google" 6 ;;
        *surface*|*lumia*|*windows*) _dm_try_vendor "Microsoft" 7 ;;
        *dell*|*latitude*|*inspiron*|*xps*|*precision*|*optiplex*) _dm_try_vendor "Dell" 4 ;;
        *lenovo*|*thinkpad*|*thinkcentre*|*ideapad*|*legion*) _dm_try_vendor "Lenovo" 6 ;;
        *hp*|*pavilion*|*omen*|*elitebook*|*probook*|*zbook*) _dm_try_vendor "HP" 2 ;;
        *asus*|*rog*|*tuf*|*zenbook*|*vivobook*) _dm_try_vendor "ASUS" 4 ;;
        *acer*|*aspire*|*predator*|*nitro*) _dm_try_vendor "Acer" 4 ;;
        *espressif*|*esp32*|*esp8266*) _dm_try_vendor "Espressif" 8 ;;
        *tuya*|*smart-life*) _dm_try_vendor "Tuya" 4 ;;
        *yeelight*) _dm_try_vendor "Yeelight" 8 ;;
        *midea*) _dm_try_vendor "Midea" 5 ;;
        *haier*|*u-home*) _dm_try_vendor "Haier" 5 ;;
    esac

    echo "$_DM_BEST_VENDOR"
}

# ============================================================
# Level 5: DHCP fingerprint (Option 55) analysis
# ============================================================
dhcp_fingerprint_lookup() {
    local mac="$1"

    # Check dnsmasq log for Option 55
    local logfile=""
    [ -f "/tmp/dnsmasq.log" ] && logfile="/tmp/dnsmasq.log"
    [ -f "/var/log/dnsmasq.log" ] && logfile="/var/log/dnsmasq.log"

    if [ -n "$logfile" ]; then
        local opt55=$(grep -i "$mac" "$logfile" 2>/dev/null | grep 'req-opt:' | tail -1 | sed 's/.*req-opt: *//' | tr -d ' ')
        if [ -n "$opt55" ]; then
            case "$opt55" in
                *1,3,6,15,26,28,51*|*1,3,6,15,26,28,51,58,59,119,121*) echo "Apple"; return ;;
                *1,3,6,12,15,21,23,28,36,42*|*1,3,6,12,15,21,23,28,36,42,119,121*) echo "Android"; return ;;
                *1,3,6,15,31,33,43,44*|*1,3,6,15,31,33,43,44,46,47,119,121,249,252*) echo "Windows"; return ;;
                *1,3,6,12,15,17,28,42*|*1,3,6,12,15,17,28,42,119,121*) echo "Linux"; return ;;
            esac
        fi
    fi

    # Check DHCP lease vendor class (field 5)
    if [ -f "$DHCP_LEASES" ]; then
        local vendor_class=$(grep -i "$mac" "$DHCP_LEASES" 2>/dev/null | awk '{print $5}')
        case "$vendor_class" in
            MSFT|windows) echo "Windows"; return ;;
            Apple|MacOS) echo "Apple"; return ;;
            android) echo "Android"; return ;;
        esac
    fi

    echo ""
}

# ============================================================
# Level 6: nlbwmon protocol analysis
# ============================================================
detect_by_nlbwmon() {
    local mac="$1"
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
    [ ! -f "$NLBWMON_CACHE" ] && { echo ""; return; }

    # Cache is JSON: {"columns":[...],"data":[["TCP",443,"mac",...,"layer7"],...]}
    # Split data rows, filter by MAC, extract layer7 (last field)
    local tmpfile="/tmp/nlbw_proto_$$"
    grep "$mac" "$NLBWMON_CACHE" | sed 's/\],\[/\n/g' | grep "$mac" | while IFS=',' read -r row; do
        layer7=$(echo "$row" | sed 's/^.*"\([^"]*\)"$/\1/' | awk -F'"' '{print $(NF-1)}')
        # Skip null/empty, non-identifying, and non-protocol values
        [ -z "$layer7" ] && continue
        [ "$layer7" = "null" ] && continue
        # Skip values that look like MAC addresses
        echo "$layer7" | grep -q ":" && continue
        echo "$layer7"
    done | sort -u > "$tmpfile"

    local protocols=$(cat "$tmpfile" 2>/dev/null | tr '\n' ' ')
    rm -f "$tmpfile"
    [ -z "$protocols" ] && { echo ""; return; }

    # Match protocol combinations to vendors
    echo "$protocols" | grep -q "Apple Push Service" && { echo "Apple"; return; }

    local has_gcm=0 has_xmpp=0 has_rdp=0 has_imaps=0
    echo "$protocols" | grep -q "Google Cloud Messaging" && has_gcm=1
    echo "$protocols" | grep -q "XMPP" && has_xmpp=1
    echo "$protocols" | grep -q "Microsoft RDP" && has_rdp=1
    echo "$protocols" | grep -q "IMAPS" && has_imaps=1

    if [ "$has_gcm" -eq 1 ] && [ "$has_xmpp" -eq 1 ]; then
        echo "Samsung"; return
    fi
    if [ "$has_rdp" -eq 1 ]; then
        echo "Microsoft"; return
    fi
    if [ "$has_imaps" -eq 1 ] && [ "$has_gcm" -eq 1 ]; then
        echo "Android"; return
    fi
    # Single GCM alone is NOT strong evidence (Chrome/Google apps on PC also use it)
    # Apple Push Service is strong (only Apple devices)
    # Do NOT return on single GCM - let other levels decide
    echo ""
}

# ============================================================
# Level 7: Traffic pattern analysis (conntrack ports)
# ============================================================
detect_type_by_traffic() {
    local mac="$1"
    local ip=$(grep -i "$mac" "$ARP_TABLE" 2>/dev/null | awk '{print $1}' | head -1)
    [ -z "$ip" ] && { echo ""; return; }

    local conntrack="/proc/net/nf_conntrack"
    [ ! -f "$conntrack" ] && { echo ""; return; }

    # Extract all dport values from connections where device is src (forward direction)
    # conntrack line: "proto src=<IP> dst=<IP> sport=X dport=Y ... src=<IP> dst=<IP> sport=X dport=Y"
    # We grep for lines where device is src=, then extract all dport= values
    # Even if some are reverse direction, we're checking for known port patterns (5223/5228/etc)
    local ports=$(grep "src=$ip " "$conntrack" 2>/dev/null | grep -o 'dport=[0-9]*' | sed 's/dport=//' | sort -u)

    local has_phone_ports=0
    local has_pc_ports=0
    local has_iot_ports=0

    for port in $ports; do
        case "$port" in
            5223|5228) has_phone_ports=1 ;;
            554|8554|5060|5061|5555|5260) has_phone_ports=1 ;;
            1883|8883|5683|5684|49152|49153|6668|9999|8080|8443|8529) has_iot_ports=1 ;;
            3389|22|445|139|135|5900|5901|2011) has_pc_ports=1 ;;
        esac
    done

    if [ "$has_pc_ports" -eq 1 ] && [ "$has_phone_ports" -eq 0 ]; then
        echo "pc"
    elif [ "$has_iot_ports" -eq 1 ] && [ "$has_phone_ports" -eq 0 ] && [ "$has_pc_ports" -eq 0 ]; then
        echo "iot"
    elif [ "$has_phone_ports" -eq 1 ]; then
        echo "phone"
    else
        echo ""
    fi
}

# ============================================================
# Auto-generate device name from vendor and type
# Similar to Lua's auto_name function
# ============================================================
auto_name() {
    local vendor="$1"
    local devtype="$2"

    # Skip if vendor is empty, unknown, or LAA
    [ -z "$vendor" ] && return
    [ "$vendor" = "Unknown" ] && return
    [ "$vendor" = "LAA" ] && return

    # Shorten vendor name
    local short=$(echo "$vendor" | sed \
        -e 's/ Mobile Communication//g' \
        -e 's/ Corporation//g' \
        -e 's/ Inc\.//g' \
        -e 's/ Co\..*$//g' \
        -e 's/ Technology//g' \
        -e 's/ TECHNOLOGY CO\.,LTD\.//g' \
        -e 's/ CO\.,LTD\.//g' \
        -e 's/ CO\.//g' \
        -e 's/ /-/g')

    [ -z "$short" ] && return

    # If no type, just return vendor short name
    if [ -z "$devtype" ] || [ "$devtype" = "unknown" ]; then
        echo "$short"
        return
    fi

    # Return vendor-type format
    echo "${short}-${devtype}"
}

# ============================================================
# Comprehensive device type detection
# ============================================================
detect_device_type() {
    local mac="$1"
    local hostname="$2"
    local vendor="$3"

    # Handle LAA devices specially
    case "$vendor" in
        "LAA"|"LAA Device"|"Mobile Device")
            # Try to infer from hostname or traffic
            local h=$(echo "$hostname" | tr 'A-Z' 'a-z')
            case "$h" in
                *iphone*|*ipad*|*android*|*pixel*|*galaxy*|*mi-*|*redmi*) echo "phone"; return ;;
                *desktop*|*laptop*|*pc*|*macbook*|*surface*) echo "pc"; return ;;
            esac
            ;;
    esac

    # Stage 1: Match by vendor (order matters: specific vendors first, generic second)
    # IMPORTANT: Some vendors make both network gear AND phones (Xiaomi, Huawei, ASUS, ZTE)
    # For these, check hostname first to avoid misclassification
    local v=$(echo "$vendor" | tr 'A-Z' 'a-z')
    local h=$(echo "$hostname" | tr 'A-Z' 'a-z')

    # Multi-category vendors: check hostname for phone/pc signals BEFORE vendor match
    # Xiaomi: phones (Redmi, Mi), routers (AX3600, etc.)
    case "$v" in
        *xiaomi*)
            case "$h" in
                *redmi*|*mi-*|*mi_*|*pocophone*|*pad[0-9]*|*xiaomi-phone*) echo "phone"; return ;;
                *ax*|*cr*|*hd*|*rm*|*rb*|*mi-r4*|*mi-router*) echo "network"; return ;;
            esac
            echo "network"; return ;;
    esac
    # Huawei: phones (Mate, P, Honor), routers (AX3, etc.)
    case "$v" in
        *huawei*|*honor*)
            case "$h" in
                *mate*|*nova*|*p[0-9]*|*y[0-9]*|*honor*|*h-de-*) echo "phone"; return ;;
                *ax*|*hd*|*k*|*ws*|*eg*|*hg*|*b*|*s*|*pro*|*wifi*|*router*) echo "network"; return ;;
            esac
            # Honor H- prefix (e.g. H-de-S20)
            case "$h" in h-*) echo "phone"; return ;; esac
            echo "phone"; return ;;
    esac
    # ASUS: phones (ZenFone), routers (RT-AX88U)
    case "$v" in
        *asus*)
            case "$h" in
                *zenfone*|*padfone*|*rog-phone*) echo "phone"; return ;;
                *rt-*|*rp-*|*lyra*|*zenwifi*|*mesh*) echo "network"; return ;;
            esac
            echo "pc"; return ;;
    esac
    # ZTE: phones (Axon, Blade), routers
    case "$v" in
        *zte*)
            case "$h" in
                *axon*|*blade*|*nubia*) echo "phone"; return ;;
            esac
            echo "network"; return ;;
    esac

    # Single-category vendors (no ambiguity)
    case "$v" in
        # Network vendors
        *cisco*|*tp-link*|*netgear*|*ubiquiti*|*mikrotik*|*hiwifi*|*mercury*|*comheart*|*telecom*)
            echo "network"; return ;;
        # Phone vendors
        *apple*|*samsung*|*oppo*|*vivo*|*oneplus*|*realme*|*google*|*android*|*nokia*|*motorola*|*sony*|*lg*|*htc*|*blackberry*|*lenovo*|*microsoft*|*meizu*)
            echo "phone"; return ;;
        # PC vendors
        *dell*|*hp*|*acer*|*msi*|*razer*|*intel*|*realtek*|*windows*|*giga*|*gigabyte*)
            echo "pc"; return ;;
        # IoT vendors
        *espressif*|*tuya*|*broadlink*|*yeelight*|*midea*|*haier*|*brother*|*epson*|*canon*)
            echo "iot"; return ;;
    esac

    # Stage 2: Match by hostname (structured prefix + keyword)
    # Honor prefix: H-<region>-<model>
    case "$h" in
        h-*)
            local model=$(echo "$h" | sed 's/^h-[a-z]*-//')
            [ -n "$model" ] && [ "$model" != "$h" ] && { echo "phone"; return; }
            ;;
    esac
    # OPPO prefix
    case "$h" in cph-*|rmx-*) echo "phone"; return ;; esac
    # vivo prefix
    case "$h" in v[0-9]*|V[0-9]*) echo "phone"; return ;; esac
    # Xiaomi codenames
    case "$h" in
        mido|nitrogen|cepheus|raphael|davinci|vayu|begonia|nabu|alioth|surya|merlin|lancelot|monet|rosemary|joyeuse|biloba|citrus|olive|oliva|pipa|fog|dandelion|evergo|cannon|lisa|munch|stone|marble)
            echo "phone"; return ;;
    esac
    # Full keyword matching
    case "$h" in
        *iphone*|*ipad*|*redmi*|*samsung*|*galaxy*|*huawei*|*honor*|*oppo*|*vivo*|*pixel*|*oneplus*|*realme*|*mate*|*nova*|*reno*|*find*|*nokia*|*lumia*|*windows-phone*|*motorola*|*xperia*|*Honor*)
            echo "phone"; return ;;
        *s20*|*s21*|*s22*|*s23*|*s24*|*s25*|*note10*|*note20*|*a[0-9][0-9]*|*j[0-9]*)
            echo "phone"; return ;;
        *desktop*|*laptop*|*pc*|*thinkpad*|*latitude*|*pavilion*|*xps*|*ideapad*|*macbook*|*imac*|*surface*|*legion*|*omen*|*rog*|*zenbook*|*vivobook*|*inspiron*|*aspire*|*predator*|*nitro*|*optiplex*|*elitebook*|*probook*|*zbook*|*precision*)
            echo "pc"; return ;;
        *esp*|*tuya*|*yeelight*|*midea*|*haier*|*smart*|*plug*|*bulb*|*sensor*|*switch*|*camera*|*door*|*lock*|*thermostat*|*aircon*|*purifier*)
            echo "iot"; return ;;
        *router*|*ap-*|*gateway*|*bridge*|*repeater*|*satellite*|*wax-*|*wax*)
            echo "network"; return ;;
    esac

    echo "unknown"
}

# ============================================================
# Master identification: 7-level chain, ALL run, then vote
# Confidence weights:
#   L1/L2 OUI:        HIGH   (direct MAC registration)
#   L3 mDNS:          MEDIUM (service advertisement)
#   L4 hostname:      LOW    (user-settable, unreliable)
#   L5 DHCP fingerprint: HIGH (OS-level protocol signature)
#   L6 nlbwmon:       HIGH   (observed protocol behavior)
#   L7 traffic ports: MEDIUM (connection patterns)
#
# Resolution: HIGH evidence overrides LOW evidence
#   If L5/L6/L7 disagree with L4, trust L5/L6/L7
# ============================================================
identify_vendor() {
    local mac="$1"
    local ip="$2"
    local hostname="$3"

    # Run ALL levels, collect results
    local l1=$(lookup_oui_local "$mac")
    local l2=$(lookup_oui_remote "$mac")
    local l3=""
    if [ -n "$ip" ]; then
        local mdns_name=$(mdns_probe_ip "$ip")
        [ -n "$mdns_name" ] && l3=$(infer_vendor_from_mdns "$mdns_name")
    fi
    local l4=$(infer_vendor_from_hostname "$hostname")
    local l5=$(dhcp_fingerprint_lookup "$mac")
    local l6=$(detect_by_nlbwmon "$mac")

    # Check if MAC is LAA (random MAC)
    local first_byte=$(echo "$mac" | tr -d ':' | cut -c1-2)
    local byte_val=$(printf '%d' "0x$first_byte" 2>/dev/null)
    local is_laa=0
    [ $((byte_val & 2)) -ne 0 ] && is_laa=1

    # Collect HIGH evidence (OUI, protocol-based)
    local high_vendor=""
    for v in "$l1" "$l2" "$l5" "$l6"; do
        if [ -n "$v" ] && [ "$v" != "Unknown" ] && [ "$v" != "LAA" ]; then
            if [ -z "$high_vendor" ]; then
                high_vendor="$v"
            elif [ "$high_vendor" != "$v" ]; then
                # HIGH evidence conflicts - trust protocol-based (L5, L6) over OUI
                case "$v" in
                    "$l5") high_vendor="$l5" ;;
                    "$l6") high_vendor="$l6" ;;
                esac
            fi
        fi
    done

    # For LAA devices, try traffic-based detection if no other evidence
    if [ "$is_laa" = "1" ] && [ -z "$high_vendor" ]; then
        # Try to detect by traffic ports (Level 7)
        if [ -n "$ip" ]; then
            local traffic_type=$(detect_type_by_traffic "$mac")
            case "$traffic_type" in
                phone) high_vendor="Mobile Device" ;;
                pc) high_vendor="Computer" ;;
                iot) high_vendor="IoT Device" ;;
            esac
        fi

        # If still no vendor, use a generic LAA label
        if [ -z "$high_vendor" ]; then
            high_vendor="LAA Device"
        fi
    fi

    # For LAA devices: try conntrack-based vendor detection to identify specific vendor
    # (e.g., Apple via port 5223, Google via port 5228)
    if [ "$is_laa" = "1" ]; then
        case "$high_vendor" in
            "Mobile Device"|"Computer"|"IoT Device"|"LAA Device"|"")
                if type detect_vendor_by_conntrack >/dev/null 2>&1; then
                    local conntrack_vendor=$(detect_vendor_by_conntrack "$mac")
                    if [ -n "$conntrack_vendor" ]; then
                        high_vendor="$conntrack_vendor"
                    fi
                fi
                ;;
        esac
    fi

    # For LAA devices: if HIGH evidence is generic (Mobile Device/Computer/IoT Device/LAA Device)
    # but L4 hostname inference provides a specific vendor, prefer the specific one
    if [ "$is_laa" = "1" ] && [ -n "$high_vendor" ]; then
        case "$high_vendor" in
            "Mobile Device"|"Computer"|"IoT Device"|"LAA Device")
                # These are generic - check if L3/L4 can provide specific vendor
                if [ -n "$l3" ]; then
                    high_vendor="$l3"
                elif [ -n "$l4" ]; then
                    high_vendor="$l4"
                fi
                ;;
        esac
    fi

    # If HIGH evidence found, return it (overrides L4)
    if [ -n "$high_vendor" ]; then
        echo "$high_vendor"
        return
    fi

    # For LAA devices with no OUI match, prioritize mDNS and hostname
    # MEDIUM evidence (L3 mDNS)
    if [ -n "$l3" ]; then
        echo "$l3"
        return
    fi

    # LOW evidence (L4 hostname) - elevated for LAA devices
    if [ -n "$l4" ]; then
        echo "$l4"
        return
    fi

    # No vendor identified
    if [ "$is_laa" = "1" ]; then
        echo "LAA"
        return
    fi
    echo ""
}

# ============================================================
# Master identification: device type (uses vendor + traffic)
# ============================================================
identify_type() {
    local mac="$1"
    local ip="$2"
    local hostname="$3"
    local vendor="$4"

    # First try: vendor + hostname based detection (only if result is meaningful)
    local dtype=$(detect_device_type "$mac" "$hostname" "$vendor")
    if [ -n "$dtype" ] && [ "$dtype" != "unknown" ]; then
        echo "$dtype"
        return
    fi

    # Second try: traffic pattern analysis (critical for LAA/randomized MACs with no OUI)
    if [ -n "$ip" ]; then
        local dtype=$(detect_type_by_traffic "$mac")
        if [ -n "$dtype" ]; then
            echo "$dtype"
            return
        fi
    fi

    echo "unknown"
}

# ============================================================
# Fetch DHCP leases from main router via ubus RPC (for Mesh sub-nodes)
# No SSH key needed — uses HTTP JSON-RPC to main router's ubus
# Caches result for 120 seconds to avoid repeated requests
# Cache format: one line per lease — "mac ip hostname"
# ============================================================
MAIN_LEASES_CACHE="/tmp/dm_main_leases"

fetch_main_router_leases() {
    # Skip if cache is fresh (< 24 hours old)
    # Cache file format: first line = timestamp, subsequent lines = lease data
    if [ -f "$MAIN_LEASES_CACHE" ]; then
        local cache_age=$(( $(date +%s) - $(sed -n '1p' "$MAIN_LEASES_CACHE" 2>/dev/null) ))
        [ "$cache_age" -lt 86400 ] && return 0
    fi

    # Get main router IP from default gateway
    local main_router=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    [ -z "$main_router" ] && return 1

    # Get credentials from UCI config (try named section, then anonymous)
    local main_user=$(uci -q get devicemaster.settings.main_router_user 2>/dev/null)
    local main_pass=$(uci -q get devicemaster.settings.main_router_pass 2>/dev/null)
    # Fallback: try anonymous settings section
    [ -z "$main_user" ] && main_user=$(uci -q get devicemaster.@settings[0].main_router_user 2>/dev/null)
    [ -z "$main_pass" ] && main_pass=$(uci -q get devicemaster.@settings[0].main_router_pass 2>/dev/null)
    # Default: require explicit configuration
    [ -z "$main_user" ] && main_user="root"
    [ -z "$main_pass" ] && return 1

    # Step 1: Login to main router via ubus RPC (timeout 5s to avoid blocking discover_all)
    local login_json="{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"00000000000000000000000000000000\",\"session\",\"login\",{\"username\":\"$main_user\",\"password\":\"$main_pass\"}]}"
    local login_result=$(wget -qO- --timeout=5 --post-data="$login_json" \
        --header='Content-Type: application/json' \
        "http://${main_router}/ubus" 2>/dev/null)

    local sid=$(echo "$login_result" | jsonfilter -e '$.result[1].ubus_rpc_session' 2>/dev/null)
    [ -z "$sid" ] && return 1

    # Step 2: Call luci-rpc getDHCPLeases (timeout 5s)
    local leases_json="{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"$sid\",\"luci-rpc\",\"getDHCPLeases\",{}]}"
    local leases_result=$(wget -qO- --timeout=5 --post-data="$leases_json" \
        --header='Content-Type: application/json' \
        "http://${main_router}/ubus" 2>/dev/null)

    # Step 3: Parse JSON and extract mac ip hostname (one per line)
    # Uses jsonfilter if available, otherwise grep+sed
    local parsed=""
    if command -v jsonfilter >/dev/null 2>&1; then
        # Count leases
        local count=$(echo "$leases_result" | jsonfilter -e '$.result[1].dhcp_leases[*].macaddr' 2>/dev/null | wc -l)
        local i=0
        while [ "$i" -lt "$count" ]; do
            local l_mac=$(echo "$leases_result" | jsonfilter -e "$.result[1].dhcp_leases[$i].macaddr" 2>/dev/null)
            local l_ip=$(echo "$leases_result" | jsonfilter -e "$.result[1].dhcp_leases[$i].ipaddr" 2>/dev/null)
            local l_hostname=$(echo "$leases_result" | jsonfilter -e "$.result[1].dhcp_leases[$i].hostname" 2>/dev/null)
            # Filter out meaningless hostnames
            case "$l_hostname" in
                ""|"*"|"-"|unknown|wlan0|lan) l_hostname="" ;;
            esac
            if [ -n "$l_mac" ] && [ -n "$l_ip" ]; then
                echo "${l_mac} ${l_ip} ${l_hostname}"
            fi
            i=$((i + 1))
        done >> "$MAIN_LEASES_CACHE"
    else
        # Fallback: use grep + sed for basic parsing
        echo "$leases_result" | sed 's/},{/}\n{/g' | \
            grep -o '"macaddr":"[^"]*"[^}]*"ipaddr":"[^"]*"[^}]*"hostname":"[^"]*"' | \
            sed 's/"macaddr":"//;s/".*ipaddr":"/ /;s/".*hostname":"/ /;s/"//' | \
            while IFS=' ' read -r l_mac l_ip l_hostname; do
                case "$l_hostname" in ""|"*"|"-"|unknown|wlan0|lan) continue ;; esac
                echo "${l_mac} ${l_ip} ${l_hostname}"
            done >> "$MAIN_LEASES_CACHE"
    fi

    # Prepend timestamp as first line (BusyBox-compatible: no stat -c)
    local ts=$(date +%s)
    local data=$(cat "$MAIN_LEASES_CACHE" 2>/dev/null)
    { echo "$ts"; echo "$data"; } > "$MAIN_LEASES_CACHE"

    if [ -s "$MAIN_LEASES_CACHE" ]; then
        log_msg "Fetched DHCP leases from main router ($main_router): $(($(wc -l < "$MAIN_LEASES_CACHE") - 1)) entries"
        return 0
    fi

    return 1
}

# Lookup hostname from main router's DHCP leases cache
# Usage: get_hostname_from_main_leases <mac>
get_hostname_from_main_leases() {
    local mac="$1"
    [ -z "$mac" ] && return
    [ ! -f "$MAIN_LEASES_CACHE" ] && return

    # Case-insensitive MAC match
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
    local hostname=$(awk -v m="$mac_lower" 'BEGIN{FS=OFS=" "} tolower($1)==m {print $3; exit}' "$MAIN_LEASES_CACHE" 2>/dev/null)
    if [ -n "$hostname" ]; then
        echo "$hostname"
    fi
}

# ============================================================
# Fast hostname probe (for Mesh sub-nodes without DHCP leases)
# Priority:
#   1. Local DHCP leases (/tmp/dhcp.leases)
#   2. Main router DHCP leases (via SSH, cached 60s)
#   3. DNS reverse lookup (nslookup)
#   4. mDNS reverse resolve (only when PROBE_MDNS=1)
# Returns: hostname string or empty
# ============================================================
probe_hostname() {
    local ip="$1"
    local mac="$2"
    [ -z "$ip" ] && return

    local result=""

    # Method 1: Local DHCP leases (fastest)
    if [ -n "$mac" ]; then
        result=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
        if [ -n "$result" ] && [ "$result" != "*" ]; then
            echo "$result"
            return
        fi
    fi

    # Method 2: Main router DHCP leases (via SSH, cached)
    if [ -n "$mac" ]; then
        fetch_main_router_leases
        result=$(get_hostname_from_main_leases "$mac")
        if [ -n "$result" ]; then
            echo "$result"
            return
        fi
    fi

    # Method 3: DNS reverse lookup via local dnsmasq (~10ms)
    if command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup "$ip" 127.0.0.1 2>/dev/null | grep -i "name = " | head -1 | sed 's/.*name = //' | sed 's/\..*//')
        if [ -n "$result" ]; then
            # Filter out meaningless results (e.g. "wlan0" from OpenWrt)
            case "$result" in
                ""|"*"|"-"|unknown|wlan0|lan) result="" ;;
            esac
            # Filter out auto-generated numeric suffixes (dnsmasq artifacts)
            # e.g., MobileDevicephone2, Mobile-Device-phone-2, etc.
            if [ -n "$result" ]; then
                case "$result" in
                    *phone[0-9]*|*pc[0-9]*|*iot[0-9]*|*network[0-9]*|*device[0-9]*|\
                    *-phone-[0-9]*|*-pc-[0-9]*|*-iot-[0-9]*|*-network-[0-9]*|*-device-[0-9]*|\
                    *Devicephone*|*Devicepc*|*Deviceiot*|*Devicenetwork*)
                        result=""
                        ;;
                esac
            fi
            if [ -n "$result" ]; then
                echo "$result"
                return
            fi
        fi
    fi

    # Method 4: mDNS reverse resolve (slower, ~500ms)
    # Only used when PROBE_MDNS=1 (set by reidentify, not discover)
    if [ "${PROBE_MDNS:-0}" = "1" ] && command -v avahi-resolve >/dev/null 2>&1; then
        result=$(avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' | sed 's/\.local$//')
        if [ -n "$result" ]; then
            echo "$result"
            return
        fi
    fi

    echo ""
}

# ============================================================
# Sanitize hostname: keep only ASCII alphanumeric, hyphens, underscores, dots
# Filters out garbled/encoding-broken strings from mDNS/DNS
# ============================================================
sanitize_hostname() {
    local raw="$1"
    [ -z "$raw" ] && return

    # Fix Apple mDNS names: Unicode private-use chars get encoded as visible digits
    # e.g. "iPad032pro032M4" -> "iPad Pro M4", "iPhone03215s032" -> "iPhone 15s"
    # Pattern: digit sequence (032,033,etc) between lowercase/uppercase transitions
    raw=$(echo "$raw" | sed -e 's/\([a-zA-Z]\)0\{1,2\}[0-9]\{2,3\}\([a-zA-Z]\)/\1 \2/g' \
                            -e 's/\([a-zA-Z]\)0\{1,2\}[0-9]\{2,3\}$/\1/g' \
                            -e 's/^0\{1,2\}[0-9]\{2,3\}\([a-zA-Z]\)/\1/g')

    # Keep only safe ASCII chars: a-z A-Z 0-9 - _ . space
    local clean=$(echo "$raw" | tr -cd 'a-zA-Z0-9._- ' | sed 's/^[. _-]*//;s/[. _-]*$//;s/  */ /g')
    # If result is too short or empty, discard
    if [ ${#clean} -lt 2 ]; then
        return
    fi
    echo "$clean"
}

# ============================================================
# UCI helpers
# ============================================================
mac_exists_in_uci() {
    local mac="$1"
    local ip="$2"
    # Normalize MAC to lowercase for case-insensitive comparison
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local stored_mac=$(uci -q get "devicemaster.@device[$idx].mac")
        # Normalize stored MAC to lowercase for comparison
        local stored_mac_lower=$(echo "$stored_mac" | tr 'A-F' 'a-f')
        if [ "$stored_mac_lower" = "$mac_lower" ]; then
            if [ -n "$ip" ]; then
                uci -q set "devicemaster.@device[$idx].last_ip=$ip"
                uci -q commit devicemaster
            fi
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

# Find device index by MAC address
find_device_index() {
    local mac="$1"
    local mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local stored_mac=$(uci -q get "devicemaster.@device[$idx].mac")
        local stored_mac_lower=$(echo "$stored_mac" | tr 'A-F' 'a-f')
        if [ "$stored_mac_lower" = "$mac_lower" ]; then
            echo "$idx"
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

# ============================================================
# Check if MAC is LAA (Locally Administered Address)
# ============================================================
is_laa_mac() {
    local mac="$1"
    local first_byte=$(echo "$mac" | tr -d ':' | cut -c1-2)
    local byte_val=$(printf '%d' "0x$first_byte" 2>/dev/null)
    [ $((byte_val & 2)) -ne 0 ] && return 0
    return 1
}

# ============================================================
# Find and merge device with same hostname/vendor/type
# Returns: merged=1 if merged, merged=0 if not
# If merged, sets: merged_idx, merged_mac, merged_ip
# ============================================================
try_merge_device() {
    local new_mac="$1"
    local new_ip="$2"
    local new_hostname="$3"
    local new_vendor="$4"
    local new_type="$5"

    merged=0
    merged_idx=""
    merged_mac=""
    merged_ip=""

    # Skip if hostname is empty or meaningless
    [ -z "$new_hostname" ] && return
    case "$new_hostname" in
        "*"|"-"|unknown|wlan0|android-*)
            return ;;
    esac

    # Only merge LAA devices
    is_laa_mac "$new_mac" || return

    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local old_mac=$(uci -q get "devicemaster.@device[$idx].mac" | tr 'a-f' 'A-F')
        local old_hostname=$(uci -q get "devicemaster.@device[$idx].hostname")
        local old_vendor=$(uci -q get "devicemaster.@device[$idx].vendor")
        local old_type=$(uci -q get "devicemaster.@device[$idx].type")
        local old_ip=$(uci -q get "devicemaster.@device[$idx].last_ip")
        local old_alt_macs=$(uci -q get "devicemaster.@device[$idx].alt_macs")

        # Check if same hostname, vendor, type
        # Match against both primary MAC and alt_macs
        local mac_matches=0
        if [ "$old_mac" = "$new_mac" ]; then
            mac_matches=1
        fi
        # Also check if new_mac is already in alt_macs
        if [ -n "$old_alt_macs" ]; then
            local IFS=','
            for alt in $old_alt_macs; do
                if [ "$(echo "$alt" | tr 'a-f' 'A-F')" = "$new_mac" ]; then
                    mac_matches=1
                    break
                fi
            done
            unset IFS
        fi

        if [ "$mac_matches" = "1" ]; then
            # Device already merged into this record, just update IP
            uci -q set "devicemaster.@device[$idx].last_ip=$new_ip"
            uci -q set "devicemaster.@device[$idx].last_seen=$(date +%s)"
            uci -q commit devicemaster
            merged=1
            merged_idx="$idx"
            merged_mac="$new_mac"
            merged_ip="$new_ip"
            return
        fi

        if [ "$old_hostname" = "$new_hostname" ] && \
           [ "$old_vendor" = "$new_vendor" ] && \
           [ "$old_type" = "$new_type" ] && \
           [ "$old_mac" != "$new_mac" ]; then

            # Check if old device is offline (not in ARP table)
            local old_online=$(grep -i "$old_mac" /proc/net/arp 2>/dev/null | grep -v "00:00:00:00:00:00" | wc -l)

            if [ "$old_online" = "0" ]; then
                # Old device is offline, can merge
                log_msg "Merging device $new_mac into existing device $old_mac (same $new_hostname)"

                # Keep the old MAC as primary, add new MAC to alt_macs
                # This preserves the original device identity and allows unlimited merges
                local current_alt=$(uci -q get "devicemaster.@device[$idx].alt_macs")
                if [ -z "$current_alt" ]; then
                    uci -q set "devicemaster.@device[$idx].alt_macs=$new_mac"
                else
                    # Check if new_mac already in alt_macs
                    if ! echo ",$current_alt," | grep -qi ",$new_mac,"; then
                        uci -q set "devicemaster.@device[$idx].alt_macs=$current_alt,$new_mac"
                    fi
                fi

                # Update IP and timestamp
                uci -q set "devicemaster.@device[$idx].last_ip=$new_ip"
                uci -q set "devicemaster.@device[$idx].last_seen=$(date +%s)"

                # Add new MAC to mac_history for tracking
                local mac_history=$(uci -q get "devicemaster.@device[$idx].mac_history")
                if [ -z "$mac_history" ]; then
                    mac_history="$new_mac"
                else
                    if ! echo "$mac_history" | grep -q "$new_mac"; then
                        mac_history="$mac_history,$new_mac"
                    fi
                fi
                uci -q set "devicemaster.@device[$idx].mac_history=$mac_history"

                uci -q commit devicemaster

                merged=1
                merged_idx="$idx"
                merged_mac="$new_mac"
                merged_ip="$new_ip"
                return
            fi
        fi
        idx=$((idx + 1))
    done
}

# ============================================================
# Register a device to UCI
# ============================================================
register_device() {
    local mac=$(echo "$1" | tr 'a-f' 'A-F')
    local ip="$2"
    local hostname="$3"

    [ "$hostname" = "*" ] && hostname=""

    # Try to get more detailed hostname from mDNS even if DHCP provided one
    # Fix: mDNS may provide more detailed device name (e.g. iPad-Pro-M4 vs iPad)
    # probe_hostname prioritizes DHCP leases, so we directly call mdns_probe_ip
    local mdns_hostname=$(mdns_probe_ip "$ip")
    if [ -n "$mdns_hostname" ]; then
        # Use mDNS hostname if it's more detailed (longer) than DHCP hostname
        if [ -z "$hostname" ] || [ ${#mdns_hostname} -gt ${#hostname} ]; then
            hostname="$mdns_hostname"
        fi
    fi

    # Sanitize hostname: filter out garbled/encoding-broken strings
    hostname=$(sanitize_hostname "$hostname")

    # Run 7-level identification
    local vendor=$(identify_vendor "$mac" "$ip" "$hostname")
    local devtype=$(identify_type "$mac" "$ip" "$hostname" "$vendor")

    # Try to merge with existing device (same hostname/vendor/type, old device offline)
    try_merge_device "$mac" "$ip" "$hostname" "$vendor" "$devtype"

    if [ "$merged" = "1" ]; then
        log_msg "Device $mac merged into existing record (hostname: $hostname)"

        # Bug fix: Delete the new device's UCI entry if it was already created
        # (e.g., by a concurrent discover_all or DHCP event)
        local del_idx=0
        while uci -q get "devicemaster.@device[$del_idx].mac" >/dev/null 2>&1; do
            local del_mac=$(uci -q get "devicemaster.@device[$del_idx].mac" | tr 'a-f' 'A-F')
            if [ "$del_mac" = "$mac" ] && [ "$del_idx" != "$merged_idx" ]; then
                log_msg "Removing duplicate UCI entry for merged device $mac at index $del_idx"
                uci -q delete "devicemaster.@device[$del_idx]"
                uci -q commit devicemaster
                break
            fi
            del_idx=$((del_idx + 1))
        done

        return
    fi

    # Use file lock to prevent concurrent device creation
    local lock_file="/tmp/devicemaster_add_device.lock"
    local lock_wait=0
    while [ -f "$lock_file" ] && [ $lock_wait -lt 10 ]; do
        sleep 0.1
        lock_wait=$((lock_wait + 1))
    done
    touch "$lock_file"
    
    # Check if device already exists - update hostname if mDNS provides better name
    # Fix: update existing device hostname if mDNS provides more detailed name
    local existing_idx=""
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local stored_mac=$(uci -q get "devicemaster.@device[$idx].mac" | tr 'a-f' 'A-F')
        if [ "$stored_mac" = "$mac" ]; then
            existing_idx=$idx
            break
        fi
        idx=$((idx + 1))
    done
    if [ -n "$existing_idx" ]; then
        local current_hostname=$(uci -q get "devicemaster.@device[$existing_idx].hostname")
        local current_manual=$(uci -q get "devicemaster.@device[$existing_idx].manual")
        # Only update if not manually set and new hostname is more detailed
        if [ "$current_manual" != "1" ] && [ -n "$hostname" ] && [ ${#hostname} -gt ${#current_hostname} ]; then
            uci -q set "devicemaster.@device[$existing_idx].hostname=$hostname"
            uci -q commit devicemaster
            log_msg "Updated hostname for $mac: $current_hostname -> $hostname"
            # Also sync to dnsmasq - ONLY on main router
            if is_mesh_main_router; then
                /usr/libexec/devicemaster/sync_hostname.sh "$mac" "$hostname" "$ip" >/dev/null 2>&1
            fi
        fi
        rm -f "$lock_file"
        return
    fi

    # Auto-generate name only if hostname is meaningless
    local name=""
    local is_meaningless=0
    case "$hostname" in
        ""|"*"|"-"|unknown|wlan0|android-*)
            is_meaningless=1 ;;
    esac
    if [ "$is_meaningless" = "0" ] && echo "$hostname" | grep -qiE '^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}'; then
        is_meaningless=1
    fi
    if [ "$is_meaningless" = "1" ] && [ -n "$vendor" ] && [ "$vendor" != "LAA" ] && [ "$vendor" != "Unknown" ] && [ -n "$devtype" ] && [ "$devtype" != "unknown" ]; then
        name=$(auto_name "$vendor" "$devtype")
    fi

    # Create UCI section
    local section=$(uci -q add devicemaster device)
    uci -q set "devicemaster.$section.mac=$mac"
    uci -q set "devicemaster.$section.hostname=$hostname"
    uci -q set "devicemaster.$section.name=$name"
    uci -q set "devicemaster.$section.last_ip=$ip"
    uci -q set "devicemaster.$section.vendor=$vendor"
    uci -q set "devicemaster.$section.type=$devtype"
    uci -q set "devicemaster.$section.discovered=1"
    uci -q set "devicemaster.$section.discovered_at=$(date +%s)"
    uci -q set "devicemaster.$section.blocked=0"
    uci -q commit devicemaster
    
    # Release lock
    rm -f "$lock_file"

    log_msg "Registered $mac as $vendor ($devtype) at $ip"

    # Sync to dnsmasq static lease (via dedicated script to avoid index bugs)
    # ONLY sync on mesh main router - must have dhcp server enabled
    if is_mesh_main_router; then
        if [ -n "$hostname" ] && [ -n "$ip" ]; then
            /usr/libexec/devicemaster/sync_hostname.sh "$mac" "$hostname" "$ip" >/dev/null 2>&1
        fi
    else
        log_msg "Skipping dhcp sync for $mac - not main router (no dhcp server)"
    fi
}

# ============================================================
# Cleanup duplicate UCI entries (same MAC, case-insensitive)
# Keeps the first occurrence, removes duplicates
# ============================================================
cleanup_duplicate_devices() {
    local seen_file="/tmp/dm_cleanup_seen"
    > "$seen_file"
    local changed=0
    local idx=0
    local to_delete=""

    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local raw_mac=$(uci -q get "devicemaster.@device[$idx].mac")
        local lower_mac=$(echo "$raw_mac" | tr 'A-F' 'a-f')

        if grep -q "^${lower_mac}$" "$seen_file" 2>/dev/null; then
            to_delete="$idx $to_delete"
            changed=1
            log_msg "Found duplicate UCI entry for $lower_mac at index $idx, will remove"
        else
            echo "$lower_mac" >> "$seen_file"
        fi
        idx=$((idx + 1))
    done

    rm -f "$seen_file"

    # Delete from highest index first to avoid index shift
    for dup_idx in $(echo "$to_delete" | tr ' ' '\n' | sort -rn); do
        uci -q delete "devicemaster.@device[$dup_idx]"
    done

    if [ "$changed" = "1" ]; then
        uci -q commit devicemaster
        log_msg "Cleaned up $(echo $to_delete | wc -w) duplicate UCI device entries"
    fi
}

# ============================================================
# DHCP event handler (called by dnsmasq)
# ============================================================
main() {
    local action="$1"
    local mac="$2"
    local ip="$3"
    local hostname="$4"

    # Lowercase MAC - must work without external commands (dnsmasq jail has no tr/awk)
    # Use printf + sed as fallback; if sed also unavailable, skip (non-critical for DHCP events)
    mac=$(printf '%s' "$mac" 2>/dev/null | sed 's/A/a/g;s/B/b/g;s/C/c/g;s/D/d/g;s/E/e/g;s/F/f/g' 2>/dev/null)
    [ -z "$mac" ] && mac="$2"
    [ "$action" != "add" ] && exit 0
    [ -z "$mac" ] && exit 0
    [ "$mac" = "00:00:00:00:00:00" ] && exit 0

    # Filter out APIPA (169.254.x.x) self-assigned addresses
    # These are NOT real DHCP addresses - iOS devices generate them before disconnecting
    case "$ip" in
        169.254.*) log_msg "Ignored APIPA address for $mac ($ip)"; exit 0 ;;
    esac

    if mac_exists_in_uci "$mac"; then
        # Update hostname if provided and not manually set
        if [ -n "$hostname" ] && [ "$hostname" != "*" ]; then
            local idx=$(find_device_index "$mac")
            if [ -n "$idx" ]; then
                local current_hostname=$(uci -q get "devicemaster.@device[$idx].hostname")
                local current_manual=$(uci -q get "devicemaster.@device[$idx].manual")
                if [ "$current_manual" != "1" ] && [ ${#hostname} -gt ${#current_hostname} ]; then
                    uci -q set "devicemaster.@device[$idx].hostname=$hostname"
                    uci -q commit devicemaster
                    log_msg "Updated hostname for $mac: $current_hostname -> $hostname"
                fi
            fi
        fi
        log_msg "Updated last_ip for $mac -> $ip"
        exit 0
    fi

    # Skip if discover_all is running (prevents race condition)
    if [ -d "/tmp/dm_discover.lock" ]; then
        log_msg "discover_all running, skipping DHCP register for $mac"
        exit 0
    fi

    log_msg "New device: $mac ($hostname) at $ip"
    register_device "$mac" "$ip" "$hostname"
}

# ============================================================
# Discover mode: batch register all ARP devices
# ============================================================
discover_all() {
    # Lock to prevent concurrent discover (device_monitor.sh + manual trigger)
    local lock="/tmp/dm_discover.lock"
    if ! mkdir "$lock" 2>/dev/null; then
        log_msg "discover_all: already running, skipping"
        return
    fi
    trap 'rmdir "$lock" 2>/dev/null' EXIT

    # Cleanup any existing duplicate UCI entries
    cleanup_duplicate_devices

    # Build MAC set first (needed for both ARP and DHCP discovery)
    # Include alt_macs to prevent re-discovering merged device aliases
    local mac_set=""
    local idx=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local stored=$(uci -q get "devicemaster.@device[$idx].mac")
        local stored_lower=$(echo "$stored" | tr 'A-F' 'a-f')
        mac_set="$mac_set $stored_lower "
        # Also add alt_macs (merged device aliases)
        local alts=$(uci -q get "devicemaster.@device[$idx].alt_macs")
        if [ -n "$alts" ]; then
            local IFS=','
            for alt in $alts; do
                local alt_lower=$(echo "$alt" | tr 'A-F' 'a-f')
                mac_set="$mac_set $alt_lower "
            done
            unset IFS
        fi
        idx=$((idx + 1))
    done

    # Pre-fetch main router leases once for all devices (cached 60s)
    fetch_main_router_leases

    local arp_tmp="/tmp/dm_discover_arp"
    awk 'NR>1 && $4!="00:00:00:00:00:00" && $3!="0x0" {print $1, $4}' /proc/net/arp 2>/dev/null > "$arp_tmp"

    # Also build DHCP-only device list (devices in leases but not in ARP)
    # These are devices that had DHCP leases but are currently offline (not in ARP)
    local dhcp_tmp="/tmp/dm_discover_dhcp"
    > "$dhcp_tmp"
    while IFS=" " read -r ts mac ip hostname rest; do
        [ -z "$mac" ] && continue
        mac=$(echo "$mac" | tr 'A-F' 'a-f')
        # Skip if already in UCI
        echo "$mac_set" | grep -q " $mac " && continue
        # Skip if already discovered from ARP this run
        grep -q " $mac$" "$arp_tmp" 2>/dev/null && continue
        # Skip entries with no IP (truly offline, cannot register without IP)
        [ -z "$ip" ] && continue
        [ "$ip" = "0.0.0.0" ] && continue
        # Valid: add to DHCP-only list
        echo "$ip $mac" >> "$dhcp_tmp"
    done < /tmp/dhcp.leases 2>/dev/null

    local modified=0
    while read -r ip mac; do
        [ -z "$mac" ] && continue
        mac=$(echo "$mac" | tr 'A-F' 'a-f')

        # Fast check: is MAC in our set?
        if echo "$mac_set" | grep -q " $mac "; then
            # Find the device and update IP + re-identify if type is unknown
            local update_idx=0
            while uci -q get "devicemaster.@device[$update_idx].mac" >/dev/null 2>&1; do
                local check_mac=$(uci -q get "devicemaster.@device[$update_idx].mac" | tr 'A-F' 'a-f')
                if [ "$check_mac" = "$mac" ]; then
                    local dhcp_ip=$(awk -v m="$mac" 'tolower($2) == m {print $3; exit}' /tmp/dhcp.leases 2>/dev/null)
                    local effective_ip="$ip"
                    [ -n "$dhcp_ip" ] && effective_ip="$dhcp_ip"
                    uci -q set "devicemaster.@device[$update_idx].last_ip=$effective_ip"

                    # Sync hostname from DHCP leases if missing or stale
                    local current_hostname=$(uci -q get "devicemaster.@device[$update_idx].hostname")
                    local current_manual=$(uci -q get "devicemaster.@device[$update_idx].manual")
                    local hostname_updated=0

                    # Fix: Clear auto-generated hostnames with numeric suffixes (dnsmasq artifacts)
                    # Matches patterns like: Mobile-Device-phone-2, MobileDevicephone2, etc.
                    if [ -n "$current_hostname" ] && [ "$current_manual" != "1" ]; then
                        case "$current_hostname" in
                            *-phone-[0-9]*|*-pc-[0-9]*|*-iot-[0-9]*|*-network-[0-9]*|*-laa-[0-9]*|\
                            *phone[0-9]*|*pc[0-9]*|*iot[0-9]*|*network[0-9]*|*device[0-9]*|\
                            *Devicephone*|*Devicepc*|*Deviceiot*|*Devicenetwork*)
                                uci -q delete "devicemaster.@device[$update_idx].hostname"
                                log_msg "Cleared auto-generated numeric hostname for $mac: $current_hostname"
                                current_hostname=""
                                modified=1
                                ;;
                        esac
                    fi

                    if [ "$current_manual" != "1" ]; then
                        local dhcp_hostname=$(awk -v m="$mac" 'tolower($2) == m {print $4; exit}' /tmp/dhcp.leases 2>/dev/null)
                        if [ -n "$dhcp_hostname" ] && [ "$dhcp_hostname" != "*" ]; then
                            # Filter out auto-generated hostnames from dnsmasq static leases
                            # These are artifacts from duplicate detection, not real device hostnames
                            # Matches: Mobile-Device-phone-2, MobileDevicephone, MobileDevicephone2, etc.
                            local is_auto_generated=0
                            case "$dhcp_hostname" in
                                *phone[0-9]*|*pc[0-9]*|*iot[0-9]*|*network[0-9]*|*device[0-9]*|\
                                *-phone-[0-9]*|*-pc-[0-9]*|*-iot-[0-9]*|*-network-[0-9]*|*-device-[0-9]*|\
                                *Devicephone*|*Devicepc*|*Deviceiot*|*Devicenetwork*)
                                    is_auto_generated=1 ;;
                            esac
                            if [ "$is_auto_generated" = "0" ]; then
                                dhcp_hostname=$(sanitize_hostname "$dhcp_hostname")
                                # Only update if sanitize produced a valid result longer than current
                                if [ -n "$dhcp_hostname" ] && [ ${#dhcp_hostname} -gt ${#current_hostname} ]; then
                                    uci -q set "devicemaster.@device[$update_idx].hostname=$dhcp_hostname"
                                    log_msg "Updated hostname for $mac: $current_hostname -> $dhcp_hostname"
                                    hostname_updated=1
                                fi
                            fi
                        fi
                    fi

                    # Re-identify if type is unknown (LAA or no match from first registration)
                    local current_type=$(uci -q get "devicemaster.@device[$update_idx].type")
                    local current_vendor=$(uci -q get "devicemaster.@device[$update_idx].vendor")
                    # Re-identify vendor for LAA devices with generic vendor names
                    local need_vendor_reidentify=0
                    case "$current_vendor" in
                        "LAA Device"|"LAA"|"Mobile Device"|"Computer"|"IoT Device"|"Unknown"|"")
                            need_vendor_reidentify=1 ;;
                    esac
                    if [ "$need_vendor_reidentify" = "1" ] || [ "$current_type" = "unknown" ]; then
                        local hostname=$(uci -q get "devicemaster.@device[$update_idx].hostname")
                        [ -z "$hostname" ] && hostname=$(awk -v m="$mac" 'tolower($2) == m {print $4; exit}' /tmp/dhcp.leases 2>/dev/null)
                        [ -z "$hostname" ] || [ "$hostname" = "*" ] && hostname=$(probe_hostname "$effective_ip" "$mac")
                        hostname=$(sanitize_hostname "$hostname")
                        if [ "$need_vendor_reidentify" = "1" ]; then
                            local new_vendor=$(identify_vendor "$mac" "$effective_ip" "$hostname")
                            if [ -n "$new_vendor" ] && [ "$new_vendor" != "$current_vendor" ]; then
                                uci -q set "devicemaster.@device[$update_idx].vendor=$new_vendor"
                                log_msg "Re-identified vendor for $mac: $current_vendor -> $new_vendor"
                            fi
                            current_vendor="$new_vendor"
                        fi
                        local new_type=$(identify_type "$mac" "$effective_ip" "$hostname" "$current_vendor")
                        if [ -n "$new_type" ] && [ "$new_type" != "unknown" ]; then
                            uci -q set "devicemaster.@device[$update_idx].type=$new_type"
                            log_msg "Re-identified device $mac: type=$new_type (via traffic analysis)"
                        fi
                    fi
                    modified=1
                    # Sync hostname to dnsmasq if it was updated
                    if [ "$hostname_updated" = "1" ] && [ -n "$dhcp_hostname" ] && [ -n "$effective_ip" ] && is_mesh_main_router; then
                        /usr/libexec/devicemaster/sync_hostname.sh "$mac" "$dhcp_hostname" "$effective_ip" >/dev/null 2>&1
                    fi
                    break
                fi
                update_idx=$((update_idx + 1))
            done
            continue
        fi

        # New device - double-check with UCI (paranoid check)
        if mac_exists_in_uci "$mac" "$ip"; then
            # Race condition: device was added by another process
            # Add to set to prevent duplicate processing
            mac_set="$mac_set $mac "
            modified=1
            continue
        fi

        local hostname=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')

        # Fallback: if no DHCP hostname (e.g. Mesh sub-node with dhcp ignore=1),
        # try main router leases + DNS reverse lookup
        if [ -z "$hostname" ] || [ "$hostname" = "*" ]; then
            hostname=$(probe_hostname "$ip" "$mac")
        fi

        # Sanitize hostname: filter out garbled/encoding-broken strings
        hostname=$(sanitize_hostname "$hostname")

        register_device "$mac" "$ip" "$hostname"

        # Add to set to prevent duplicate in same loop
        mac_set="$mac_set $mac "
        modified=1
    done < "$arp_tmp"
    rm -f "$arp_tmp"

    # Also discover DHCP-only devices (in leases but not in ARP, e.g. offline devices)
    if [ -s "$dhcp_tmp" ]; then
        while read -r ip mac; do
            [ -z "$mac" ] && continue
            mac=$(echo "$mac" | tr 'A-F' 'a-f')
            # Double-check not already in UCI (race condition)
            if mac_exists_in_uci "$mac" "$ip"; then
                mac_set="$mac_set $mac "
                modified=1
                continue
            fi
            # Get hostname from DHCP leases
            local hostname=$(grep -i " $mac " /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
            [ "$hostname" = "*" ] && hostname=""
            register_device "$mac" "$ip" "$hostname"
            mac_set="$mac_set $mac "
            modified=1
        done < "$dhcp_tmp"
    fi
    rm -f "$dhcp_tmp"

    uci -q commit devicemaster 2>/dev/null

    # Sync all device hostnames to dnsmasq static leases
    # This ensures OpenWrt default device list shows correct names
    if is_mesh_main_router && [ -x "/usr/libexec/devicemaster/sync_hostname.sh" ]; then
        local idx=0
        while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
            local s_mac=$(uci -q get "devicemaster.@device[$idx].mac")
            local s_hostname=$(uci -q get "devicemaster.@device[$idx].hostname")
            local s_name=$(uci -q get "devicemaster.@device[$idx].name")
            local s_ip=$(uci -q get "devicemaster.@device[$idx].last_ip")
            local s_manual=$(uci -q get "devicemaster.@device[$idx].manual")
            # Determine sync name: prefer hostname, fallback to name if hostname invalid
            local sync_name=""
            if [ -n "$s_hostname" ] && [ "$s_hostname" != "*" ] && [ "$s_hostname" != "unknown" ]; then
                sync_name="$s_hostname"
            elif [ -n "$s_name" ] && [ "$s_name" != "*" ] && [ "$s_name" != "unknown" ]; then
                sync_name="$s_name"
            fi
            # Skip if no valid name, manually set, or no IP
            if [ -n "$sync_name" ] && [ "$s_manual" != "1" ] && [ -n "$s_ip" ]; then
                /usr/libexec/devicemaster/sync_hostname.sh "$s_mac" "$sync_name" "$s_ip" >/dev/null 2>&1
            fi
            idx=$((idx + 1))
        done
    fi

    rmdir "$lock" 2>/dev/null
}

# ============================================================
# Re-identify mode: re-run 7-level chain for existing devices
# ============================================================
reidentify_all() {
    local idx=0
    local fixed=0
    while uci -q get "devicemaster.@device[$idx].mac" >/dev/null 2>&1; do
        local mac=$(uci -q get "devicemaster.@device[$idx].mac")
        local old_vendor=$(uci -q get "devicemaster.@device[$idx].vendor")
        local old_type=$(uci -q get "devicemaster.@device[$idx].type")
        local hostname=$(uci -q get "devicemaster.@device[$idx].hostname")
        local ip=$(uci -q get "devicemaster.@device[$idx].last_ip")
        local manual=$(uci -q get "devicemaster.@device[$idx].manual")
        local discovered=$(uci -q get "devicemaster.@device[$idx].discovered")

        # Skip manually annotated devices (user has set vendor/type by hand)
        if [ "$manual" = "1" ]; then
            idx=$((idx + 1))
            continue
        fi

        # Refresh hostname from DHCP leases if empty
        if [ -z "$hostname" ]; then
            hostname=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
            [ "$hostname" = "*" ] && hostname=""
        fi
        # Fallback: try DNS reverse lookup if still empty (Mesh sub-node)
        if [ -z "$hostname" ] && [ -n "$ip" ]; then
            hostname=$(probe_hostname "$ip")
        fi
        # Filter out auto-generated hostnames before saving
        if [ -n "$hostname" ]; then
            local is_auto_generated=0
            case "$hostname" in
                *phone[0-9]*|*pc[0-9]*|*iot[0-9]*|*network[0-9]*|*device[0-9]*|\
                *-phone-[0-9]*|*-pc-[0-9]*|*-iot-[0-9]*|*-network-[0-9]*|*-device-[0-9]*|\
                *Devicephone*|*Devicepc*|*Deviceiot*|*Devicenetwork*)
                    is_auto_generated=1 ;;
            esac
            if [ "$is_auto_generated" = "0" ]; then
                uci -q set "devicemaster.@device[$idx].hostname=$hostname"
            fi
        fi

        local new_vendor=$(identify_vendor "$mac" "$ip" "$hostname")
        local new_type=$(identify_type "$mac" "$ip" "$hostname" "$new_vendor")

        local changed=0
        if [ "$new_vendor" != "$old_vendor" ] && [ -n "$new_vendor" ]; then
            uci -q set "devicemaster.@device[$idx].vendor=$new_vendor"
            changed=1
        fi
        if [ "$new_type" != "$old_type" ] && [ -n "$new_type" ]; then
            uci -q set "devicemaster.@device[$idx].type=$new_type"
            changed=1
        fi

        # Auto-generate name only if hostname is meaningless AND name is not set
        # Meaningless: empty, *, -, MAC address, unknown, wlan0, etc.
        local old_name=$(uci -q get "devicemaster.@device[$idx].name")
        local old_hostname=$(uci -q get "devicemaster.@device[$idx].hostname")

        # Fix: Clear auto-generated hostnames with numeric suffixes (dnsmasq artifacts)
        # Matches patterns like: Mobile-Device-phone-2, MobileDevicephone2, etc.
        if [ -n "$old_hostname" ] && [ "$manual" != "1" ]; then
            case "$old_hostname" in
                *-phone-[0-9]*|*-pc-[0-9]*|*-iot-[0-9]*|*-network-[0-9]*|*-laa-[0-9]*|\
                *phone[0-9]*|*pc[0-9]*|*iot[0-9]*|*network[0-9]*|*device[0-9]*|\
                *Devicephone*|*Devicepc*|*Deviceiot*|*Devicenetwork*)
                    uci -q delete "devicemaster.@device[$idx].hostname"
                    old_hostname=""
                    changed=1
                    log_msg "Cleared auto-generated numeric hostname for $mac: $old_hostname"
                    ;;
            esac
        fi

        # If hostname is now meaningful but name was auto-generated (vendor-type format),
        # clear the auto-name so display falls back to hostname
        if [ -n "$old_name" ] && [ -n "$old_hostname" ] && [ "$manual" != "1" ]; then
            local is_meaningless=0
            case "$old_hostname" in
                ""|"*"|"-"|unknown|wlan0|android-*)
                    is_meaningless=1 ;;
            esac
            if [ "$is_meaningless" = "0" ] && echo "$old_hostname" | grep -qiE '^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}'; then
                is_meaningless=1
            fi
            # Hostname is meaningful, auto-name should be cleared
            if [ "$is_meaningless" = "0" ]; then
                uci -q delete "devicemaster.@device[$idx].name"
                old_name=""
                changed=1
            fi
        fi

        if [ -z "$old_name" ]; then
            local is_meaningless=0
            case "$old_hostname" in
                ""|"*"|"-"|unknown|wlan0|android-*)
                    is_meaningless=1 ;;
            esac
            # Check if hostname looks like a MAC address
            if [ "$is_meaningless" = "0" ] && echo "$old_hostname" | grep -qiE '^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}'; then
                is_meaningless=1
            fi
            # Only auto-name when hostname is meaningless AND we have vendor+type
            if [ "$is_meaningless" = "1" ] && [ -n "$new_vendor" ] && [ "$new_vendor" != "LAA" ] && [ "$new_vendor" != "Unknown" ] && [ -n "$new_type" ] && [ "$new_type" != "unknown" ]; then
                local new_name=$(auto_name "$new_vendor" "$new_type")
                if [ -n "$new_name" ]; then
                    uci -q set "devicemaster.@device[$idx].name=$new_name"
                    changed=1
                fi
            fi
        fi

        if [ "$changed" = "1" ]; then
            log_msg "Re-identified $mac: $old_vendor/$old_type -> $new_vendor/$new_type"
            fixed=$((fixed + 1))
        fi
        idx=$((idx + 1))
    done
    uci -q commit devicemaster 2>/dev/null
    echo "Re-identified $fixed devices"
}

# ============================================================
# Entry point
# When sourced (e.g. ". event_handler.sh"), only load functions — do NOT execute main
# ============================================================
if [ "${0##*/}" = "event_handler.sh" ] || [ -n "$1" ]; then
case "$1" in
    discover)   discover_all; exit 0 ;;
    reidentify) reidentify_all; exit 0 ;;
    *)          main "$@" ;;
esac
fi
