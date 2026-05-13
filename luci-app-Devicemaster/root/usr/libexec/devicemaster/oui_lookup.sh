#!/bin/sh
# OUI Lookup Module
# Supports: remote API query / local database (optional)

OUI_CACHE_FILE="/tmp/devicemaster_oui_cache.txt"
OUI_CACHE_TTL=86400  # 24 hours
OUI_DB="/usr/share/devicemaster/oui.txt"

# Remote API endpoints
API_MACLOOKUP="maclookup"      # https://api.maclookup.app/v2/macs/
API_MACVENDORS="macvendors"    # https://api.macvendors.com/

# Get OUI mode from UCI config
get_oui_mode() {
    local mode=$(uci get devicemaster.settings.oui_mode 2>/dev/null)
    echo "${mode:-remote}"  # default: remote
}

# Get remote API preference
get_remote_api() {
    local api=$(uci get devicemaster.settings.remote_api 2>/dev/null)
    echo "${api:-maclookup}"  # default: maclookup
}

# Check if MAC is LAA (Locally Administered Address / Random MAC)
# LAA: first byte bit 1 = 1 (0x02, 0x06, 0x0A, 0x0E, 0x12, 0x16, ...)
is_laa_mac() {
    local mac="$1"
    local first_byte=$(echo "$mac" | tr -d ':' | cut -c1-2)
    local byte_val=$(printf '%d' "0x$first_byte" 2>/dev/null)
    # Bit 1 set = LAA
    [ $((byte_val & 2)) -ne 0 ] && return 0
    return 1
}

# Lookup OUI - main entry point
lookup_oui() {
    local mac="$1"
    [ -z "$mac" ] && return

    # LAA (Random MAC) check - skip OUI lookup for random MACs
    if is_laa_mac "$mac"; then
        echo "LAA"
        return
    fi

    local oui=$(echo "$mac" | tr -d ':' | cut -c1-6 | tr 'a-f' 'A-F')
    [ -z "$oui" ] && return

    local mode=$(get_oui_mode)

    if [ "$mode" = "local" ] && [ -f "$OUI_DB" ]; then
        # Local database mode
        lookup_oui_local "$oui"
    else
        # Remote query mode (default)
        lookup_oui_remote "$oui"
    fi
}

# Lookup from local database
lookup_oui_local() {
    local oui="$1"
    grep -i "^$oui|" "$OUI_DB" 2>/dev/null | cut -d'|' -f2 | head -1
}

# Lookup from remote API with caching (single file)
lookup_oui_remote() {
    local oui="$1"

    # Check cache file first
    if [ -f "$OUI_CACHE_FILE" ]; then
        local cached=$(grep "^${oui}|" "$OUI_CACHE_FILE" 2>/dev/null)
        if [ -n "$cached" ]; then
            # Check if cache is still valid
            local cache_time=$(echo "$cached" | cut -d'|' -f3)
            local now=$(date +%s)
            if [ $((now - cache_time)) -lt "$OUI_CACHE_TTL" ]; then
                echo "$cached" | cut -d'|' -f2
                return
            fi
        fi
    fi

    # Query remote API
    local api=$(get_remote_api)
    local vendor=""

    if [ "$api" = "macvendors" ]; then
        vendor=$(query_macvendors "$oui")
    else
        vendor=$(query_maclookup "$oui")
    fi

    if [ -n "$vendor" ] && [ "$vendor" != "Not Found" ] && [ "$vendor" != "null" ]; then
        # Save to cache (format: OUI|VENDOR|TIMESTAMP)
        local now=$(date +%s)
        # Remove old entry if exists
        if [ -f "$OUI_CACHE_FILE" ]; then
            grep -v "^${oui}|" "$OUI_CACHE_FILE" > "${OUI_CACHE_FILE}.tmp" 2>/dev/null
            mv "${OUI_CACHE_FILE}.tmp" "$OUI_CACHE_FILE"
        fi
        echo "${oui}|${vendor}|${now}" >> "$OUI_CACHE_FILE"
        echo "$vendor"
    else
        echo "Unknown"
    fi
}

# Query maclookup.app API (JSON format)
query_maclookup() {
    local oui="$1"

    local response=$(curl -s --max-time 10 \
        "https://api.maclookup.app/v2/macs/${oui}" 2>/dev/null)

    [ -z "$response" ] && return

    # Parse JSON: {"company":"Apple, Inc.",...}
    echo "$response" | grep -o '"company":"[^"]*"' | cut -d'"' -f4
}

# Query macvendors.com API (plain text)
query_macvendors() {
    local oui="$1"

    local response=$(curl -s --max-time 10 \
        "https://api.macvendors.com/${oui}" 2>/dev/null)

    [ -z "$response" ] && return

    # Return plain text response
    echo "$response" | tr -d '\n\r'
}

# Test API and return response time
# Usage: test_api <maclookup|macvendors> [test_mac]
test_api() {
    local api="$1"
    local test_mac="${2:-00:11:22:33:44:55}"
    local oui=$(echo "$test_mac" | tr -d ':' | cut -c1-6 | tr 'a-f' 'A-F')

    echo "Testing $api API with OUI: $oui"
    echo ""

    local start_time=$(date +%s%N)
    local response=""
    local vendor=""

    if [ "$api" = "macvendors" ]; then
        response=$(curl -s --max-time 10 \
            "https://api.macvendors.com/${oui}" 2>/dev/null)
        vendor="$response"
    else
        response=$(curl -s --max-time 10 \
            "https://api.maclookup.app/v2/macs/${oui}" 2>/dev/null)
        vendor=$(echo "$response" | grep -o '"company":"[^"]*"' | cut -d'"' -f4)
    fi

    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))  # ms

    echo "Response time: ${duration}ms"
    echo "Raw response:"
    echo "$response"
    echo ""
    echo "Extracted vendor: ${vendor:-Not Found}"
}

# Convert downloaded OUI file to local format
convert_oui_file() {
    local input_file="$1"
    local output_file="$2"

    [ -z "$input_file" ] && echo "Usage: convert_oui_file <input.csv> [output.txt]" && return 1
    [ -z "$output_file" ] && output_file="/usr/share/devicemaster/oui.txt"

    echo "Converting OUI file..."

    # Create output directory
    mkdir -p "$(dirname "$output_file")"

    # Parse CSV format: Registry,Assignment,"Organization Name","Organization Address"
    # Handle both quoted and unquoted organization names
    # Output format: OUI|Vendor (uppercase OUI, truncated vendor)
    awk -F',' '
    NR > 1 {
        # OUI is always in $2 (Assignment column)
        oui = toupper($2)
        gsub(/-/, "", oui)

        # Organization Name is in $3
        # Handle quoted: "Nokia..." or unquoted: Extreme Networks
        vendor = $3
        gsub(/"/, "", vendor)

        # Clean up vendor name
        # Remove common suffixes
        if (match(vendor, /,?\s*(Co\.|Company|Corporation|Inc|Ltd)\.?\.?$/)) {
            vendor = substr(vendor, 1, RSTART - 1)
        }

        # Only output if OUI is valid (6, 7, or 9 hex chars for MA-L, MA-M, MA-S) and vendor is not empty
        if ((length(oui) == 6 || length(oui) == 7 || length(oui) == 9) && vendor != "") {
            print oui "|" vendor
        }
    }' "$input_file" > "$output_file"

    local count=$(wc -l < "$output_file")
    echo "Converted $count entries to $output_file"
}

# Download OUI database from IEEE (MA-L + MA-M + MA-S)
download_oui_database() {
    local output_file="${1:-/tmp/oui.csv}"

    echo "Downloading OUI databases from IEEE..."

    # Download MA-L (24-bit)
    echo "  - MA-L (24-bit)..."
    curl -sL --max-time 60 \
        -o "${output_file}.mal" \
        "https://standards-oui.ieee.org/oui/oui.csv" 2>/dev/null

    # Download MA-M (28-bit)
    echo "  - MA-M (28-bit)..."
    curl -sL --max-time 60 \
        -o "${output_file}.mam" \
        "https://standards-oui.ieee.org/oui28/mam.csv" 2>/dev/null

    # Download MA-S (36-bit)
    echo "  - MA-S (36-bit)..."
    curl -sL --max-time 60 \
        -o "${output_file}.mas" \
        "https://standards-oui.ieee.org/oui36/oui36.csv" 2>/dev/null

    # Merge all files
    echo "  - Merging..."
    cat "${output_file}.mal" "${output_file}.mam" "${output_file}.mas" > "$output_file"
    rm -f "${output_file}.mal" "${output_file}.mam" "${output_file}.mas"

    if [ -s "$output_file" ]; then
        local count=$(wc -l < "$output_file")
        echo "Downloaded $count entries to $output_file"
        return 0
    fi

    echo "IEEE download failed"
    return 1
}

# Install local OUI database
install_oui_database() {
    local csv_file="$1"

    [ -z "$csv_file" ] && echo "Usage: install_oui_database <oui.csv>" && return 1
    [ ! -f "$csv_file" ] && echo "File not found: $csv_file" && return 1

    convert_oui_file "$csv_file" "$OUI_DB"

    # Enable local mode
    uci set devicemaster.settings.oui_mode='local'
    uci commit devicemaster

    echo "OUI database installed. Mode set to 'local'"
}

# Clear remote cache
clear_oui_cache() {
    rm -f "$OUI_CACHE_FILE"
    echo "OUI cache cleared"
}

# Get cache stats
get_oui_cache_stats() {
    if [ -f "$OUI_CACHE_FILE" ]; then
        local count=$(grep -c "^[0-9A-F]\{6\}|" "$OUI_CACHE_FILE" 2>/dev/null || echo 0)
        local size=$(du -sh "$OUI_CACHE_FILE" 2>/dev/null | cut -f1)
        echo "Cache: $count entries ($size)"
    else
        echo "Cache: 0 entries"
    fi
}

# Command line interface
case "$1" in
    lookup)
        lookup_oui "$2"
        ;;
    test-api)
        test_api "$2" "$3"
        ;;
    download)
        download_oui_database "$2"
        ;;
    convert)
        convert_oui_file "$2" "$3"
        ;;
    install)
        install_oui_database "$2"
        ;;
    clear-cache)
        clear_oui_cache
        ;;
    stats)
        get_oui_cache_stats
        ;;
    mode)
        get_oui_mode
        ;;
    api)
        get_remote_api
        ;;
    *)
        echo "Usage: $0 {lookup <mac>|test-api <api> [mac]|download [output]|convert <input> [output]|install <csv>|clear-cache|stats|mode|api}"
        echo ""
        echo "API options:"
        echo "  maclookup    - api.maclookup.app (JSON, recommended)"
        echo "  macvendors   - api.macvendors.com (plain text)"
        exit 1
        ;;
esac
