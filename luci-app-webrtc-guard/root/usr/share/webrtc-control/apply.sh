#!/bin/sh

. /lib/functions.sh
. /lib/functions/network.sh
. /usr/share/webrtc-control/common.sh

NFT_FILE=/usr/share/nftables.d/ruleset-post/10-webrtc-control.nft
OFFLOAD_STATE=/etc/webrtc-control/offload-state
TEMP_RULES=
TEMP_ERROR=

fail() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$*" > "$ERROR_FILE"
    logger -t webrtc-control "错误: $*"
    printf '%s\n' "$*" >&2
    return 1
}

cleanup() {
    [ -z "$TEMP_RULES" ] || rm -f "$TEMP_RULES"
    [ -z "$TEMP_ERROR" ] || rm -f "$TEMP_ERROR"
}

safe_interface() {
    case "$1" in ''|*[!a-zA-Z0-9_.:@-]*) return 1 ;; esac
    [ "${#1}" -le 15 ]
}

valid_address() {
    case "$1" in ''|*[!0-9a-fA-F:./]*) return 1 ;; esac
    printf '%s\n' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]+(/[0-9]{1,3})?$'
}

valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}

collect_zone() {
    local section="$1" name networks devices network device
    config_get name "$section" name
    case " $SELECTED_ZONES " in *" $name "*) ;; *) return 0 ;; esac
    config_get networks "$section" network
    config_get devices "$section" device
    for network in $networks; do
        device=
        network_get_device device "$network" || continue
        safe_interface "$device" || continue
        COLLECTED="$COLLECTED $device"
    done
    for device in $devices; do
        safe_interface "$device" || continue
        COLLECTED="$COLLECTED $device"
    done
}

zone_devices() {
    SELECTED_ZONES="$1"
    COLLECTED=
    config_load firewall
    config_foreach collect_zone zone
    printf '%s\n' "$COLLECTED" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

wan_devices() {
    local devices network device result=
    devices=$(zone_devices "$(setting egress_zones wan)")
    for network in wan wan6; do
        device=
        network_get_device device "$network" || continue
        safe_interface "$device" || continue
        devices="$devices $device"
    done
    devices="$devices $(setting egress_devices '')"
    for device in $devices; do
        safe_interface "$device" || return 1
        result="$result $device"
    done
    printf '%s\n' "$result" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

emit_set() {
    local name="$1" type="$2" flags="$3" values="$4" quoted="$5" value first=1
    printf '    set %s { type %s; %s' "$name" "$type" "$flags"
    if [ -n "$values" ]; then
        printf ' elements = { '
        for value in $values; do
            [ "$first" = 1 ] || printf ', '
            if [ "$quoted" = 1 ]; then printf '"%s"' "$value"; else printf '%s' "$value"; fi
            first=0
        done
        printf ' };'
    fi
    printf ' }\n'
}

emit_drop() {
    local match="$1" counter="$2"
    if [ "$(setting log 1)" = 1 ]; then
        printf '        %s limit rate 10/minute burst 5 packets log prefix "webrtc-drop-%s "\n' "$match" "$counter"
    fi
    printf '        %s counter name %s drop\n' "$match" "$counter"
}

emit_inspection() {
    local doff bits framed start
    printf '    chain inspect {\n'
    if [ "$(setting dpi 1)" = 1 ]; then
        emit_drop 'meta l4proto udp udp length >= 28 @th,64,16 & 0xc000 == 0 @th,80,16 & 0x0003 == 0 @th,96,32 0x2112a442' stun_udp
        for doff in 5 6 7 8 9 10 11 12 13 14 15; do
            bits=$((doff * 32))
            for framed in 0 16; do
                start=$((bits + framed))
                emit_drop "meta l4proto tcp tcp doff $doff @th,$start,16 & 0xc000 == 0 @th,$((start + 16)),16 & 0x0003 == 0 @th,$((start + 32)),32 0x2112a442" stun_tcp
            done
        done
    fi
    if [ "$(setting ports 1)" = 1 ]; then
        emit_drop 'meta l4proto udp udp dport { 3478, 5349, 19302-19309 }' stun_ports
        emit_drop 'meta l4proto tcp tcp dport { 3478, 5349 }' stun_ports
    fi
    printf '    }\n'
}

generate_rules() {
    local ip4='' ip6='' macs='' item mode scope=''
    mode=$(setting mode proxy)
    case "$mode" in proxy|block) ;; *) fail '无效的拦截模式'; return 1 ;; esac
    [ "$(setting dpi 1)" = 1 ] || [ "$(setting ports 1)" = 1 ] || {
        fail '至少启用 STUN 特征或常见端口拦截'; return 1;
    }
    for item in $(uci -q get webrtc-control.whitelist.ip); do
        valid_address "$item" || { fail "无效的白名单地址: $item"; return 1; }
        case "$item" in *:*) ip6="$ip6 $item" ;; *) ip4="$ip4 $item" ;; esac
    done
    for item in $(uci -q get webrtc-control.whitelist.mac); do
        valid_mac "$item" || { fail "无效的白名单 MAC: $item"; return 1; }
        macs="$macs $item"
    done
    WAN_DEVICES=$(wan_devices) || { fail '出口接口名称无效'; return 1; }
    [ -n "$WAN_DEVICES" ] || { fail '无法确定真实出口接口，请设置出口防火墙区域或接口'; return 1; }
    if [ "$(setting all_zones 1)" != 1 ]; then
        scope=$(zone_devices "$(uci -q get webrtc-control.scope.zone)")
        [ -n "$scope" ] || { fail '所选生效区域没有可用接口，未扩大生效范围'; return 1; }
    fi
    {
        printf 'table inet webrtc_control {}\ndelete table inet webrtc_control\ntable inet webrtc_control {\n'
        printf '    comment "webrtc-control:%s:%s"\n' "$VERSION" "$(config_hash)"
        emit_set wan_ifaces ifname '' "$WAN_DEVICES" 1
        emit_set target_ifaces ifname '' "$scope" 1
        emit_set wl_ip4 ipv4_addr 'flags interval; auto-merge;' "$ip4" 0
        emit_set wl_ip6 ipv6_addr 'flags interval; auto-merge;' "$ip6" 0
        emit_set wl_mac ether_addr '' "$macs" 0
        printf '    counter stun_udp {}\n    counter stun_tcp {}\n    counter stun_ports {}\n'
        printf '    chain forward_guard {\n'
        printf '        ip saddr @wl_ip4 return\n        ip6 saddr @wl_ip6 return\n        ether saddr @wl_mac return\n'
        [ -z "$scope" ] || printf '        iifname != @target_ifaces return\n'
        printf '        jump inspect\n    }\n'
        printf '    chain egress {\n        type filter hook postrouting priority 90; policy accept;\n'
        if [ "$mode" = proxy ]; then printf '        oifname != @wan_ifaces return\n'; fi
        printf '        oifname "lo" return\n'
        printf '        meta iif 0 jump inspect\n        meta iif != 0 jump forward_guard\n    }\n'
        emit_inspection
        printf '}\n'
    } > "$TEMP_RULES"
}

restore_offload() {
    local software hardware current_software current_hardware
    [ -f "$OFFLOAD_STATE" ] || return 0
    software=$(sed -n 's/^software=//p' "$OFFLOAD_STATE")
    hardware=$(sed -n 's/^hardware=//p' "$OFFLOAD_STATE")
    case "$software" in 0|1|unset) ;; *) fail '流量卸载恢复记录无效'; return 1 ;; esac
    case "$hardware" in 0|1|unset) ;; *) fail '流量卸载恢复记录无效'; return 1 ;; esac
    current_software=$(uci -q get 'firewall.@defaults[0].flow_offloading')
    current_hardware=$(uci -q get 'firewall.@defaults[0].flow_offloading_hw')
    if [ "$current_software" = 0 ] && [ "$current_hardware" = 0 ]; then
        if [ "$software" = unset ]; then uci -q delete 'firewall.@defaults[0].flow_offloading'; else uci set "firewall.@defaults[0].flow_offloading=$software"; fi
        if [ "$hardware" = unset ]; then uci -q delete 'firewall.@defaults[0].flow_offloading_hw'; else uci set "firewall.@defaults[0].flow_offloading_hw=$hardware"; fi
        uci commit firewall || { fail '无法恢复流量卸载设置'; return 1; }
        fw4 reload > "$TEMP_ERROR" 2>&1 || { fail "恢复流量卸载失败: $(cat "$TEMP_ERROR")"; return 1; }
    fi
    rm -f "$OFFLOAD_STATE"
}

disable_offload() {
    local software hardware
    software=$(uci -q get 'firewall.@defaults[0].flow_offloading')
    hardware=$(uci -q get 'firewall.@defaults[0].flow_offloading_hw')
    if [ "$software" = 1 ] || [ "$hardware" = 1 ]; then
        [ "$(setting manage_offload 1)" = 1 ] || {
            fail '流量卸载会绕过检查，请关闭卸载或启用自动管理'; return 1;
        }
        mkdir -p /etc/webrtc-control
        if [ ! -f "$OFFLOAD_STATE" ]; then
            printf 'software=%s\nhardware=%s\n' "${software:-unset}" "${hardware:-unset}" > "$OFFLOAD_STATE" || return 1
            chmod 600 "$OFFLOAD_STATE"
        fi
        uci set 'firewall.@defaults[0].flow_offloading=0' &&
            uci set 'firewall.@defaults[0].flow_offloading_hw=0' &&
            uci commit firewall || { fail '无法关闭流量卸载'; return 1; }
        fw4 reload > "$TEMP_ERROR" 2>&1 || {
            fail "关闭流量卸载后的防火墙重载失败: $(cat "$TEMP_ERROR")"; return 1;
        }
    fi
    nft list flowtables > "$TEMP_ERROR" 2>&1 || { fail '无法检查流量卸载状态'; return 1; }
    if grep -q 'flowtable' "$TEMP_ERROR"; then
        fail '仍检测到流量卸载表，请关闭额外的 SFE/NSS/PPE 加速后重试'
        return 1
    fi
}

cleanup_legacy() {
    if [ -f /etc/crontabs/root ] && grep -qF '/usr/share/webrtc-control/resolve-stun.sh' /etc/crontabs/root; then
        sed -i '\|/usr/share/webrtc-control/resolve-stun.sh|d' /etc/crontabs/root
        /etc/init.d/cron reload >/dev/null 2>&1 || :
    fi
}

clear_rules() {
    if nft list table inet webrtc_control >/dev/null 2>&1; then
        nft delete table inet webrtc_control > "$TEMP_ERROR" 2>&1 || {
            fail "无法移除防护规则: $(cat "$TEMP_ERROR")"; return 1;
        }
    fi
    rm -f "$NFT_FILE"
    cleanup_legacy
    restore_offload || return 1
    rm -f "$ERROR_FILE"
    logger -t webrtc-control '已停用防护'
}

apply_rules() {
    [ "$(setting enabled 0)" = 1 ] || { clear_rules; return $?; }
    [ "$(uci -q get 'firewall.@defaults[0].auto_includes')" != 0 ] || {
        fail 'fw4 已关闭自动 include，无法保证重载后防护持续生效'; return 1;
    }
    generate_rules || return 1
    nft -c -f "$TEMP_RULES" > "$TEMP_ERROR" 2>&1 || {
        fail "规则校验失败，保留原防护: $(cat "$TEMP_ERROR")"; return 1;
    }
    disable_offload || return 1
    nft -f "$TEMP_RULES" > "$TEMP_ERROR" 2>&1 || {
        fail "规则加载失败，保留原防护: $(cat "$TEMP_ERROR")"; return 1;
    }
    mkdir -p "$(dirname "$NFT_FILE")"
    cp "$TEMP_RULES" "$NFT_FILE.new" && chmod 600 "$NFT_FILE.new" && mv -f "$NFT_FILE.new" "$NFT_FILE" || {
        fail '规则已加载但持久化失败，请重试'; return 1;
    }
    cleanup_legacy
    rm -f "$ERROR_FILE"
    logger -t webrtc-control "已应用 v$VERSION，真实出口: $WAN_DEVICES"
}

umask 077
mkdir -p "$STATE_DIR"
command -v flock >/dev/null 2>&1 || { fail '缺少 flock，请安装 flock 软件包'; exit 1; }
exec 9> "$STATE_DIR/lock"
attempt=0
until flock -n -x 9; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 15 ] || { fail '防护配置正被其他操作占用，请重试'; exit 1; }
    sleep 1
done
TEMP_RULES=$(mktemp "$STATE_DIR/rules.XXXXXX") || exit 1
TEMP_ERROR=$(mktemp "$STATE_DIR/error.XXXXXX") || exit 1
trap cleanup EXIT HUP INT TERM

case "${1:-apply}" in
    apply) apply_rules ;;
    clear) clear_rules ;;
    render) generate_rules && cat "$TEMP_RULES" ;;
    *) fail '用法: apply.sh apply|clear|render'; exit 1 ;;
esac
