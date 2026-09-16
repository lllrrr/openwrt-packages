#!/bin/sh
# System hardware summary: SoC, temperature, CoreMark, physical ports, WiFi
# BusyBox compatible

first_line() { for f in "$@"; do [ -r "$f" ] && { sed -n '1p' "$f" 2>/dev/null; return; }; done; }
trim() { sed 's/^[ \t]*//;s/[ \t]*$//'; }

BOARD_MODEL="$(first_line /tmp/sysinfo/model /proc/device-tree/model 2>/dev/null | tr -d '\000' | trim)"
[ -z "$BOARD_MODEL" ] && BOARD_MODEL="$(sed -n 's/^Hardware[ \t]*:[ \t]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
[ -z "$BOARD_MODEL" ] && BOARD_MODEL="未知"
BOARD_NAME="$(first_line /tmp/sysinfo/board_name 2>/dev/null | trim)"
COMPAT="$(tr '\000' ' ' </proc/device-tree/compatible 2>/dev/null | tr 'A-Z' 'a-z')"

SOC_MODEL=""
case "$COMPAT $BOARD_MODEL $BOARD_NAME" in
    *ipq6018*) SOC_MODEL="Qualcomm IPQ6018" ;;
    *ipq6000*) SOC_MODEL="Qualcomm IPQ6000" ;;
    *ipq6010*) SOC_MODEL="Qualcomm IPQ6010" ;;
    *ipq807*) SOC_MODEL="Qualcomm IPQ807x" ;;
    *mt7621*) SOC_MODEL="MediaTek MT7621" ;;
    *mt7981*) SOC_MODEL="MediaTek MT7981" ;;
    *mt7986*) SOC_MODEL="MediaTek MT7986" ;;
    *360t7*) SOC_MODEL="MediaTek MT7981/Filogic 820" ;;
    *re-ss-01*|*AX1800*|*ax1800*) SOC_MODEL="Qualcomm IPQ6018" ;;
    *re-cs-02*|*AX6600*|*ax6600*) SOC_MODEL="Qualcomm IPQ6018" ;;
    *) SOC_MODEL="$BOARD_MODEL" ;;
esac

CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
case "$CPU_CORES" in ''|0) CPU_CORES="$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l | tr -d ' ')" ;; esac
MAX_KHZ=0
for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    [ -r "$f" ] || continue
    v="$(cat "$f" 2>/dev/null)"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -gt "$MAX_KHZ" ] && MAX_KHZ="$v"
done
[ "$MAX_KHZ" -gt 0 ] && CPU_FREQ_MHZ=$((MAX_KHZ / 1000)) || CPU_FREQ_MHZ=""

max_temp_by_pattern() {
    pat="$1"; best=""; bestn=""
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        typ="$(cat "$z/type" 2>/dev/null)"
        echo "$typ" | grep -qi "$pat" || continue
        raw="$(cat "$z/temp" 2>/dev/null)"
        case "$raw" in ''|*[!0-9-]*) continue ;; esac
        [ "$raw" -gt 1000 ] && c=$((raw / 1000)) || c="$raw"
        if [ -z "$best" ] || [ "$c" -gt "$best" ]; then best="$c"; bestn="$typ"; fi
    done
    [ -n "$best" ] && echo "$best|$bestn"
}
SOC_T="$(max_temp_by_pattern 'cpu\|soc\|nss\|top')"
if [ -z "$SOC_T" ]; then SOC_T="$(max_temp_by_pattern '.')"; fi
SOC_TEMP_C="${SOC_T%%|*}"; SOC_TEMP_NAME="${SOC_T#*|}"
[ -z "$SOC_TEMP_C" ] && SOC_TEMP_C="N/A"
[ -z "$SOC_TEMP_NAME" ] && SOC_TEMP_NAME="thermal"
WIFI_T="$(max_temp_by_pattern 'wifi\|wlan\|radio\|phy')"
WIFI_TEMP_C="${WIFI_T%%|*}"; WIFI_TEMP_NAME="${WIFI_T#*|}"
[ -z "$WIFI_TEMP_C" ] && WIFI_TEMP_C="N/A"
[ -z "$WIFI_TEMP_NAME" ] && WIFI_TEMP_NAME=""

COREMARK=""
if [ "$1" = "coremark" ] || [ "$ACTION" = "coremark" ]; then
    if [ -x /etc/coremark.sh ]; then
        echo "COREMARK_RUN=1"
        /etc/coremark.sh 2>&1 | tee /tmp/route-tool-coremark.log
        [ -r /tmp/coremark.log ] && cat /tmp/coremark.log >> /tmp/route-tool-coremark.log
        [ -r /etc/bench.log ] && cat /etc/bench.log >> /tmp/route-tool-coremark.log
    else
        echo "COREMARK_RUN=0"
        echo "COREMARK_ERROR=/etc/coremark.sh 不存在或不可执行"
    fi
fi
if [ -r /tmp/route-tool-coremark.log ]; then
    COREMARK="$(sed -n 's/.*Iterations\/Sec[[:space:]:=]*\([0-9][0-9.]*\).*/\1/p' /tmp/route-tool-coremark.log | tail -n 1)"
    [ -z "$COREMARK" ] && COREMARK="$(sed -n 's/.*Iterations\/Sec[^0-9]*\([0-9][0-9.]*\).*/\1/p' /tmp/route-tool-coremark.log | tail -n 1)"
fi
if [ -z "$COREMARK" ] && [ -r /etc/bench.log ]; then
    COREMARK="$(sed -n 's/.*Iterations\/Sec[^0-9]*\([0-9][0-9.]*\).*/\1/p' /etc/bench.log | tail -n 1)"
    [ -z "$COREMARK" ] && COREMARK="$(sed -n 's/.*(CpuMark\s\+\([0-9][0-9.]*\).*/\1/p' /etc/bench.log | tail -n 1)"
fi
[ -z "$COREMARK" ] && COREMARK="N/A"
case "$COREMARK" in N/A|''|*[!0-9.]* ) COREMARK_SINGLE="N/A" ;; *) COREMARK_SINGLE="$(awk -v c="$COREMARK" -v n="$CPU_CORES" 'BEGIN{if(n>0) printf "%.0f", c/n; else print "N/A"}')" ;; esac

DISTRO=""
if [ -r /etc/openwrt_release ]; then
    DESC="$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p;s/^DISTRIB_DESCRIPTION=\"\(.*\)\"/\1/p" /etc/openwrt_release | head -n 1)"
    ID="$(sed -n "s/^DISTRIB_ID='\(.*\)'/\1/p;s/^DISTRIB_ID=\"\(.*\)\"/\1/p" /etc/openwrt_release | head -n 1)"
    DISTRO="${DESC:-$ID}"
fi
if grep -Riq 'qsdk\|qca' /etc/openwrt_release /etc/banner /etc/os-release 2>/dev/null; then
    SYS_FLAVOR="QSDK/QWRT系"
elif echo "$DISTRO" | grep -qi 'immortalwrt'; then
    SYS_FLAVOR="ImmortalWrt"
elif echo "$DISTRO" | grep -qi 'openwrt'; then
    SYS_FLAVOR="OpenWrt"
else
    SYS_FLAVOR="${DISTRO:-未知}"
fi

PORT_TOTAL=0; PORT_UP=0; PORT_LIST=""; PORT_TEXT=""
fmt_mbps() { s="$1"; case "$s" in ''|*[!0-9-]*) echo "" ;; -1) echo "" ;; *) if [ "$s" -ge 1000 ]; then awk -v v="$s" 'BEGIN{printf "%.1fG", v/1000}'; else echo "${s}M"; fi ;; esac; }
port_max_speed() {
    iface="$1"; max=""
    if command -v ethtool >/dev/null 2>&1; then
        info="$(ethtool "$iface" 2>/dev/null)"
        # Parse examples: 1000baseT/Full, 2500baseT/Full, 1000baseX/Full.
        # Avoid sed alternation tricks because BusyBox sed variants differ.
        max="$(printf '%s\n' "$info" | sed -n 's/.* \([0-9][0-9]*\)base.*/\1/p' | sort -n | tail -n 1)"
        [ -z "$max" ] && max="$(printf '%s\n' "$info" | sed -n 's/.*Speed: *\([0-9][0-9]*\)Mb\/s.*/\1/p' | sort -n | tail -n 1)"
    fi
    [ -n "$max" ] && { fmt_mbps "$max"; return; }
    cur="$(cat /sys/class/net/$iface/speed 2>/dev/null)"
    fmt_mbps "$cur"
}
add_port() {
    iface="$1"; label="$2"; n="/sys/class/net/$iface"
    [ -e "$n" ] || return
    carrier="$(cat "$n/carrier" 2>/dev/null)"; st="$(cat "$n/operstate" 2>/dev/null)"; raw_speed="$(cat "$n/speed" 2>/dev/null)"
    speed="$(fmt_mbps "$raw_speed")"; max_speed="$(port_max_speed "$iface")"
    PORT_TOTAL=$((PORT_TOTAL + 1))
    if [ "$carrier" = "1" ] || [ "$st" = "up" ]; then
        PORT_UP=$((PORT_UP + 1)); state="up"; shown="${speed:-已连接}"
    else
        state="down"; shown="未插线"
    fi
    [ -n "$max_speed" ] && [ "$max_speed" != "$speed" ] && shown="$shown / 最高${max_speed}"
    item="$label|$state|$shown"
    [ -z "$PORT_LIST" ] && PORT_LIST="$item" || PORT_LIST="$PORT_LIST,$item"
    line="$label $shown"
    [ -z "$PORT_TEXT" ] && PORT_TEXT="$line" || PORT_TEXT="$PORT_TEXT\\n$line"
}
add_port lan1 LAN1; add_port lan2 LAN2; add_port lan3 LAN3; add_port lan4 LAN4; add_port lan5 LAN5; add_port lan6 LAN6; add_port lan7 LAN7; add_port lan8 LAN8
[ -e /sys/class/net/utun ] && add_port utun utun
add_port wan WAN
if [ "$PORT_TOTAL" -eq 0 ]; then for n in /sys/class/net/eth*; do [ -e "$n" ] && add_port "${n##*/}" "${n##*/}"; done; fi
[ -z "$PORT_LIST" ] && PORT_LIST="N/A"

wifi_iface_list() {
    for w in /sys/class/net/wlan*; do [ -e "$w" ] && echo "${w##*/}"; done
    if command -v iwinfo >/dev/null 2>&1; then
        # Only accept the interface token from known iwinfo summary lines to avoid misreading headings/errors.
        iwinfo 2>/dev/null | sed -n 's/^\([^ ]*\)[ ][ ]*ESSID:.*/\1/p;s/^\([^ ]*\)[ ][ ]*Access Point:.*/\1/p'
    fi
    for s in /var/run/hostapd-phy*/*.conf /var/run/hostapd*.conf; do [ -r "$s" ] && sed -n 's/^interface=//p' "$s"; done
}
WIFI_TEXT=""; WIFI_LIST=""; WIFI_TOTAL=0; WIFI_UP=0
for iface in $(wifi_iface_list | sed '/^$/d' | sort -u); do
    [ -e "/sys/class/net/$iface" ] || command -v iwinfo >/dev/null 2>&1 || continue
    enabled="❌"; state="down"; band="WiFi"; rate=""; chan=""; ssid=""
    st="$(cat /sys/class/net/$iface/operstate 2>/dev/null)"
    if command -v iwinfo >/dev/null 2>&1; then
        info="$(iwinfo "$iface" info 2>/dev/null)"
        echo "$info" | grep -qi 'No such wireless device\|ESSID: unknown' || { enabled="✅"; state="up"; }
        ssid="$(echo "$info" | sed -n 's/.*ESSID: "\(.*\)".*/\1/p' | head -n 1)"
        chan="$(echo "$info" | sed -n 's/.*Channel: *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
        rate="$(echo "$info" | sed -n 's/.*Bit Rate: *\([0-9.]* [KMG]*Bit\/s\).*/\1/p' | head -n 1 | sed 's/MBit\/s/Mbps/;s/GBit\/s/Gbps/;s/KBit\/s/Kbps/;s/ //g')"
    fi
    [ "$st" = "up" ] && { enabled="✅"; state="up"; }
    case "$chan" in 1|2|3|4|5|6|7|8|9|10|11|12|13|14) band="2.4G" ;; '') band="WiFi" ;; *) band="5G" ;; esac
    WIFI_TOTAL=$((WIFI_TOTAL + 1)); [ "$state" = "up" ] && WIFI_UP=$((WIFI_UP + 1))
    shown="$enabled $band"
    [ -n "$rate" ] && shown="$shown ${rate}"
    [ -n "$chan" ] && shown="$shown CH${chan}"
    [ -n "$ssid" ] && shown="$shown ${ssid}"
    item="$iface|$state|$shown"
    [ -z "$WIFI_LIST" ] && WIFI_LIST="$item" || WIFI_LIST="$WIFI_LIST,$item"
    [ -z "$WIFI_TEXT" ] && WIFI_TEXT="$iface $shown" || WIFI_TEXT="$WIFI_TEXT; $iface $shown"
done
[ -z "$WIFI_TEXT" ] && WIFI_TEXT="N/A"
[ -z "$WIFI_LIST" ] && WIFI_LIST="N/A"

echo "SOC_MODEL=$SOC_MODEL"
echo "SOC_BOARD=$BOARD_NAME"
echo "BOARD_MODEL=$BOARD_MODEL"
echo "SOC_CORES=$CPU_CORES"
[ -n "$CPU_FREQ_MHZ" ] && echo "SOC_FREQ_MHZ=$CPU_FREQ_MHZ"
echo "SOC_TEMP_C=$SOC_TEMP_C"
echo "SOC_TEMP_NAME=$SOC_TEMP_NAME"
echo "COREMARK_SCORE=$COREMARK"
echo "COREMARK_SINGLE=$COREMARK_SINGLE"
echo "SYS_DISTRO=$DISTRO"
echo "SYS_FLAVOR=$SYS_FLAVOR"
echo "PORT_TOTAL=$PORT_TOTAL"
echo "PORT_UP=$PORT_UP"
echo "PORT_LIST=$PORT_LIST"
echo "PORT_TEXT=$PORT_TEXT"
WAN_IF="$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null)"
LAN_IF="$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null)"
[ -n "$WAN_IF" ] && echo "PORT_WAN=$WAN_IF"
[ -n "$LAN_IF" ] && echo "PORT_LAN=$LAN_IF"
echo "WIFI_TOTAL=$WIFI_TOTAL"
echo "WIFI_UP=$WIFI_UP"
echo "WIFI_LIST=$WIFI_LIST"
echo "WIFI_TEXT=$WIFI_TEXT"
echo "WIFI_TEMP_C=$WIFI_TEMP_C"
echo "WIFI_TEMP_NAME=$WIFI_TEMP_NAME"
