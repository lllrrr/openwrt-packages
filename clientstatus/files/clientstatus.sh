#!/bin/sh

# clientstatus.sh v3.2 — Monitor LAN client online/offline status
# Runs as a background daemon via procd

. /lib/functions.sh

OUTPUT_FILE="/tmp/clientstatus"
STATE_FILE="/tmp/clientstatus.state"

# ─── UCI configuration ─────────────────────────────────────────
config_load clientstatus
config_get INTERVAL  main interval  30
config_get LAN_IFACE main lan_iface "br-lan"

# ─── Heartbeat via signal ─────────────────────────────────────
echo $$ > /tmp/clientstatus.pid
FRONTEND_ACTIVE=0
trap 'FRONTEND_ACTIVE=1' USR1

IDLE_INTERVAL=600

# Conntrack threshold: 600s before kernel-established timeout
CONNTRACK_TIMEOUT=$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null)
CONNTRACK_TIMEOUT=${CONNTRACK_TIMEOUT:-7440}
CONNTRACK_THRESHOLD=$((CONNTRACK_TIMEOUT - 600))
[ "$CONNTRACK_THRESHOLD" -lt 0 ] && CONNTRACK_THRESHOLD=0

# ─── LAN subnet ────────────────────────────────────────────────
LAN_CIDR=$(ip -4 addr show dev "$LAN_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -z "$LAN_CIDR" ] && { echo "clientstatus: cannot get LAN address for $LAN_IFACE" >&2; exit 1; }
LAN_IP="${LAN_CIDR%%/*}"
LAN_PREFIX="${LAN_CIDR##*/}"

set -- $(awk -v ip="$LAN_IP" -v prefix="$LAN_PREFIX" '
function i2n(s, a) { split(s, a, "."); return a[1]*16777216+a[2]*65536+a[3]*256+a[4] }
function and32(a, b, r, p) {
    r=0; p=1; while(a>0||b>0){if(a%2==1&&b%2==1)r+=p; a=int(a/2); b=int(b/2); p*=2}; return r
}
BEGIN {
    n=i2n(ip); m=0
    for(i=0;i<prefix;i++) m=m*2+1
    for(i=prefix;i<32;i++) m=m*2
    print and32(n,m), m
}')
LAN_NET_INT=$1
LAN_MASK_INT=$2

AWK_LAN='
function ip2int(s, a) { split(s, a, "."); return a[1]*16777216+a[2]*65536+a[3]*256+a[4] }
function and32(a, b, r, p) {
    r=0; p=1; while(a>0||b>0){if(a%2==1&&b%2==1)r+=p; a=int(a/2); b=int(b/2); p*=2}; return r
}
function in_lan(ip) { return ip != "" && and32(ip2int(ip), lan_mask) == lan_net }
'

# ─── Data source emitters ──────────────────────────────────────

emit_conntrack_ips() {
    awk -v threshold="$CONNTRACK_THRESHOLD" \
        -v lan_net="$LAN_NET_INT" -v lan_mask="$LAN_MASK_INT" \
        "$AWK_LAN"'
    /^ipv6/ { next }
    {
        ip = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^src=/) { sub(/^src=/, "", $i); ip = $i; break }
        }
        if (!in_lan(ip)) next
        if (ip in seen) next
        if (/ESTABLISHED/) {
            for (j = 2; j <= NF; j++) {
                if ($j == "ESTABLISHED" && $(j-1)+0 > threshold) { seen[ip]=1; break }
            }
        } else {
            seen[ip] = 1
        }
    }
    END { for (ip in seen) print ip }
    ' /proc/net/nf_conntrack 2>/dev/null
}

emit_wifi_map() {
    [ -s "$AP_INFO" ] || return
    while IFS='|' read -r iface ssid; do
        ubus call iwinfo assoclist "{\"device\":\"$iface\"}" 2>/dev/null |
            awk -v ssid="$ssid" '{
                s = tolower($0)
                while (match(s, /[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]/)) {
                    print toupper(substr(s, RSTART, RLENGTH)) "|" ssid
                    s = substr(s, RSTART + RLENGTH)
                }
            }'
    done < "$AP_INFO" | sort -t'|' -k1,1 -u
}

emit_arp() {
    awk -v lan="$LAN_IFACE" \
        -v lan_net="$LAN_NET_INT" -v lan_mask="$LAN_MASK_INT" \
        "$AWK_LAN"'
    NR > 1 && $4 != "00:00:00:00:00:00" && $6 == lan && in_lan($1) {
        print toupper($4) "|" $1 "|arp"
    }' /proc/net/arp 2>/dev/null
}

emit_dhcp() {
    [ -f /tmp/dhcp.leases ] || return
    awk -v lan_net="$LAN_NET_INT" -v lan_mask="$LAN_MASK_INT" \
        "$AWK_LAN"'
    $1 ~ /^[0-9]+$/ {
        mac = toupper($2)
        if (split(mac, a, ":") == 6 && $3 !~ /:/ && in_lan($3))
            print mac "|" $3 "|" $4 "|dhcp"
    }' /tmp/dhcp.leases
}

emit_ping_check() {
    local candidates
    candidates=$(
        awk -F'|' -v wf="$WIFI_FILE" -v cf="$CT_FILE" -v hw="$HAS_WIFI" '
        BEGIN {
            if (hw) {
                while ((getline line < wf) > 0) { split(line, a, "|"); wifi[a[1]] = 1 }
                close(wf)
            }
            while ((getline line < cf) > 0) ct[line] = 1
            close(cf)
        }
        {
            mac = $1; ip = $2
            if (mac == "" || ip == "") next
            if (seen[mac]++) next
            if (hw && mac in wifi) next
            if (ip in ct) next
            print ip
        }' "$ARP_FILE" "$DHCP_FILE"
    )
    [ -z "$candidates" ] && return
    for ip in $candidates; do
        (ping -c1 -W1 "$ip" >/dev/null 2>&1 && echo "$ip") &
    done
    wait
}

# ─── Startup helpers ───────────────────────────────────────────

build_ap_info() {
    : > "$AP_INFO"
    for iface in $(iw dev 2>/dev/null | awk '/Interface/{f=$2} /type AP/{print f}'); do
        ssid=$(ubus call iwinfo info "{\"device\":\"$iface\"}" 2>/dev/null |
               grep -o '"ssid"[[:space:]]*:[[:space:]]*"[^"]*"' |
               sed 's/.*: *"//;s/"$//')
        [ -n "$ssid" ] && printf '%s|%s\n' "$iface" "$ssid"
    done >> "$AP_INFO"
}

flush_neigh() {
    ip -4 neigh flush dev "$LAN_IFACE" >/dev/null 2>&1
    if [ "$HAS_WIFI" = "1" ] && [ -s "$AP_INFO" ]; then
        cut -d'|' -f1 "$AP_INFO" | while read -r iface; do
            ip -4 neigh flush dev "$iface" >/dev/null 2>&1
        done
    fi
}

# ─── Main loop ─────────────────────────────────────────────────
main_loop() {
    TMPDIR=$(mktemp -d /tmp/cs.XXXXXX) || { echo "clientstatus: mktemp failed" >&2; exit 1; }
    trap "rm -rf '$TMPDIR'; exit 0" INT TERM

    AP_INFO="$TMPDIR/ap_info"
    CT_FILE="$TMPDIR/ct_ips"
    WIFI_FILE="$TMPDIR/wifi_macs"
    ARP_FILE="$TMPDIR/arp_entries"
    DHCP_FILE="$TMPDIR/dhcp_entries"
    if command -v iw >/dev/null 2>&1; then
        HAS_WIFI=1
        build_ap_info
    else
        HAS_WIFI=0
    fi
    flush_neigh
    while true; do
        NOW=$(date +%s)

        # Collect data sources — WiFi skipped entirely when no iw
        emit_conntrack_ips > "$CT_FILE"
        [ "$HAS_WIFI" = "1" ] && emit_wifi_map > "$WIFI_FILE"
        emit_arp  > "$ARP_FILE"
        emit_dhcp > "$DHCP_FILE"

        # Main awk — has_wifi gates all WiFi paths
        emit_ping_check | awk \
            -v now="$NOW" -v tmpdir="$TMPDIR" \
            -v ct_file="$CT_FILE" -v wifi_file="$WIFI_FILE" \
            -v arp_file="$ARP_FILE" -v dhcp_file="$DHCP_FILE" \
            -v state_file="$STATE_FILE" -v has_wifi="$HAS_WIFI" '
        BEGIN {
            OFS = "|"

            while ((getline line < ct_file) > 0) ct[line] = 1
            close(ct_file)

            if (has_wifi) {
                while ((getline line < wifi_file) > 0) {
                    split(line, a, "|"); wifi[a[1]] = a[2]
                }
                close(wifi_file)
            }

            while ((getline line < arp_file) > 0) {
                split(line, a, "|")
                mac = a[1]; ip = a[2]
                if (mac != "" && mac != "00:00:00:00:00:00") {
                    if (!(mac in arp_ip) || arp_ip[mac] == "") arp_ip[mac] = ip
                    seen[mac] = 1
                }
            }
            close(arp_file)

            while ((getline line < dhcp_file) > 0) {
                split(line, a, "|")
                mac = a[1]; ip = a[2]; hn = a[3]
                if (mac != "") {
                    dhcp_ip[mac] = ip
                    if (hn != "" && hn != "*") dhcp_hostname[mac] = hn
                    seen[mac] = 1
                }
            }
            close(dhcp_file)

            while ((getline line < state_file) > 0) {
                split(line, a, "|")
                mac = a[1]
                old_status[mac]   = a[2]
                old_since[mac]    = a[3] + 0
                old_ipv4[mac]     = a[4]
                old_hostname[mac] = a[5]
                old_dtype[mac]    = a[6]
                old_prio[mac]     = a[7] + 0
                old_miss[mac]     = a[8] + 0
                all_macs[mac]     = 1
            }
            close(state_file)
        }

        { pt[$0] = 1; next }

        END {
            for (m in seen)       all_macs[m] = 1
            for (m in old_status) all_macs[m] = 1

            n = 0
            for (m in all_macs) order[++n] = m
            for (i = 2; i <= n; i++) {
                key = order[i]; j = i - 1
                while (j >= 1 && order[j] > key) { order[j+1] = order[j]; j-- }
                order[j+1] = key
            }

            out_state = ""; out_online = ""; out_offline = ""

            for (idx = 1; idx <= n; idx++) {
                mac = order[idx]

                # IP: DHCP > ARP > old
                ip = ""
                if (mac in dhcp_ip)     ip = dhcp_ip[mac]
                else if (mac in arp_ip) ip = arp_ip[mac]
                if (ip == "" && mac in old_ipv4) ip = old_ipv4[mac]
                cur_dhcp = (mac in dhcp_ip) ? 1 : 0

                # Hostname
                hostname = ""
                if (mac in dhcp_hostname) hostname = dhcp_hostname[mac]
                if ((hostname == "" || hostname == "unknown") && mac in old_hostname)
                    hostname = old_hostname[mac]
                if (hostname == "") hostname = "unknown"

                # Device type
                if (has_wifi) {
                    is_wifi_now = (mac in wifi) ? 1 : 0
                    if (is_wifi_now) device_type = "WiFi"
                    else if (mac in old_dtype && old_dtype[mac] == "WiFi") device_type = "WiFi"
                    else device_type = "Ethernet"
                } else {
                    is_wifi_now = 0
                    device_type = "Ethernet"
                }

                # Miss count
                miss = 0
                if (mac in old_status && old_status[mac] != "online") miss = 0
                else if (mac in old_miss) miss = old_miss[mac]

                # Online/offline determination
                prio = 99
                if (has_wifi && device_type == "WiFi") {
                    online = is_wifi_now ? "online" : "offline"
                    prio = 0; miss = 0
                } else {
                    cur_conn = 0
                    if (ip != "" && ip in ct) cur_conn = 1
                    has_ping = (ip != "" && ip in pt) ? 1 : 0

                    if (cur_conn) {
                        online = "online"
                        prio = cur_dhcp ? 1 : 2
                        miss = 0
                    } else if (has_ping) {
                        online = "online"
                        prio = 3
                        miss = 0
                    } else {
                        miss++
                        if ((mac in old_prio) && old_prio[mac] == 1 && !cur_dhcp) {
                            online = "offline"; prio = 1
                        } else if ((mac in old_prio) && old_prio[mac] == 3 && miss < 3) {
                            online = (mac in old_status) ? old_status[mac] : "offline"
                            prio = (mac in old_prio) ? old_prio[mac] : 99
                        } else if (miss >= 3) {
                            online = "offline"; prio = 99
                        } else {
                            online = (mac in old_status) ? old_status[mac] : "offline"
                            prio = (mac in old_prio) ? old_prio[mac] : 99
                        }
                    }
                }

                # Timer: reset on state transition
                since = (mac in old_since) ? old_since[mac] : now
                if (online == "online") {
                    if (!(mac in old_status) || old_status[mac] != "online") since = now
                } else {
                    if (!(mac in old_status) || old_status[mac] == "online") since = now
                }
                duration = now - since

                # Display connection
                if (has_wifi && is_wifi_now)                display_conn = wifi[mac]
                else if (has_wifi && device_type == "WiFi") display_conn = "WiFi"
                else                                        display_conn = "Ethernet"

                # Format duration
                if (duration < 60)         dur = duration "s"
                else if (duration < 3600)  dur = int(duration/60) "m" (duration%60) "s"
                else if (duration < 86400) dur = int(duration/3600) "h" int((duration%3600)/60) "m"
                else                       dur = int(duration/86400) "d" int((duration%86400)/3600) "h"

                out_state = out_state mac "|" online "|" since "|" ip "|" hostname "|" device_type "|" prio "|" miss "\n"

                line = sprintf("%-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n", \
                    mac, online, dur, ip, hostname, display_conn)
                if (online == "online") out_online = out_online line
                else out_offline = out_offline line
            }

            printf "%s", out_state > (tmpdir "/new_state")
            close(tmpdir "/new_state")
            printf "%s%s", out_online, out_offline
        }
        ' > "$TMPDIR/output"

        # Assemble final output atomically
        {
            echo "# Client Status — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# Refresh interval: ${INTERVAL}s  |  LAN: ${LAN_IFACE} (${LAN_IP}/${LAN_PREFIX})"
            [ "$HAS_WIFI" = "1" ] && echo "# WiFi: enabled" || echo "# WiFi: disabled"
            echo "#"
            printf '# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n' \
                "MAC" "STATUS" "DURATION" "IPv4" "HOSTNAME" "CNT"
            printf '# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n' \
                "─────────────────" "────────" "──────────" \
                "────────────────" "────────────────────" "──────────"
            cat "$TMPDIR/output"
        } > "${OUTPUT_FILE}.tmp"
        mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

        mv "$TMPDIR/new_state" "$STATE_FILE"

        # Dynamic sleep: signal-based heartbeat
        END_TS=$(date +%s)
        ELAPSED=$(( END_TS - NOW ))

        if [ "$FRONTEND_ACTIVE" = "1" ]; then
            SLEEP_TIME=$(( INTERVAL - ELAPSED ))
        else
            SLEEP_TIME=$(( IDLE_INTERVAL - ELAPSED ))
        fi
        FRONTEND_ACTIVE=0

        [ "$SLEEP_TIME" -lt 1 ] && SLEEP_TIME=1

        sleep "$SLEEP_TIME" &
        SLEEP_PID=$!
        wait $SLEEP_PID 2>/dev/null
        kill "$SLEEP_PID" 2>/dev/null
    done
}

main_loop
