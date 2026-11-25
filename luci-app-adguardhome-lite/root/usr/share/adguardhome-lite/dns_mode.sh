#!/bin/sh
# AdGuard Home 管理中心 - DNS 接管模式管理
# 用法：dns_mode.sh apply|revert|status
# 说明：自动保存和恢复 DNSMasq 原始设置，关闭服务或切换模式时不会破坏上网。

. /usr/share/adguardhome-lite/common.sh

load_conf

ACTION="${1:-apply}"

get_uci() {
    uci -q get "$1" 2>/dev/null
}

# 保存 DNSMasq 的原始设置，仅在尚未保存时执行一次
save_original() {
    [ "$(get_uci "$CONF.main.old_captured")" = "1" ] && return 0

    old_has_port="0"
    old_port="$(get_uci dhcp.@dnsmasq[0].port)"
    [ -n "$old_port" ] && old_has_port="1"

    old_has_noresolv="0"
    old_noresolv="$(get_uci dhcp.@dnsmasq[0].noresolv)"
    [ -n "$old_noresolv" ] && old_has_noresolv="1"

    old_has_resolvfile="0"
    old_resolvfile="$(get_uci dhcp.@dnsmasq[0].resolvfile)"
    [ -n "$old_resolvfile" ] && old_has_resolvfile="1"

    old_has_server="0"
    old_servers="$(get_uci dhcp.@dnsmasq[0].server)"
    [ -n "$old_servers" ] && old_has_server="1"

    uci -q set "$CONF.main.old_has_port=$old_has_port"
    uci -q delete "$CONF.main.old_port"
    [ "$old_has_port" = "1" ] && uci -q set "$CONF.main.old_port=$old_port"

    uci -q set "$CONF.main.old_has_noresolv=$old_has_noresolv"
    uci -q delete "$CONF.main.old_noresolv"
    [ "$old_has_noresolv" = "1" ] && uci -q set "$CONF.main.old_noresolv=$old_noresolv"

    uci -q set "$CONF.main.old_has_resolvfile=$old_has_resolvfile"
    uci -q delete "$CONF.main.old_resolvfile"
    [ "$old_has_resolvfile" = "1" ] && uci -q set "$CONF.main.old_resolvfile=$old_resolvfile"

    uci -q set "$CONF.main.old_has_server=$old_has_server"
    uci -q delete "$CONF.main.old_server"
    if [ "$old_has_server" = "1" ]; then
        for _s in $old_servers; do
            uci -q add_list "$CONF.main.old_server=$_s"
        done
    fi

    uci -q set "$CONF.main.old_captured=1"
    uci -q commit "$CONF" 2>/dev/null
}

# 恢复 DNSMasq 原始设置，并清除保存的备份值
restore_original() {
    [ "$(get_uci "$CONF.main.old_captured")" = "1" ] || return 0

    if [ "$(get_uci "$CONF.main.old_has_port")" = "1" ]; then
        uci -q set "dhcp.@dnsmasq[0].port=$(get_uci "$CONF.main.old_port")"
    else
        uci -q delete dhcp.@dnsmasq[0].port
    fi

    if [ "$(get_uci "$CONF.main.old_has_noresolv")" = "1" ]; then
        uci -q set "dhcp.@dnsmasq[0].noresolv=$(get_uci "$CONF.main.old_noresolv")"
    else
        uci -q delete dhcp.@dnsmasq[0].noresolv
    fi

    if [ "$(get_uci "$CONF.main.old_has_resolvfile")" = "1" ]; then
        uci -q set "dhcp.@dnsmasq[0].resolvfile=$(get_uci "$CONF.main.old_resolvfile")"
    else
        uci -q delete dhcp.@dnsmasq[0].resolvfile
    fi

    uci -q delete dhcp.@dnsmasq[0].server
    if [ "$(get_uci "$CONF.main.old_has_server")" = "1" ]; then
        for _s in $(get_uci "$CONF.main.old_server"); do
            uci -q add_list "dhcp.@dnsmasq[0].server=$_s"
        done
    fi

    uci -q commit dhcp 2>/dev/null

    uci -q delete "$CONF.main.old_captured"
    uci -q delete "$CONF.main.old_has_port"
    uci -q delete "$CONF.main.old_port"
    uci -q delete "$CONF.main.old_has_noresolv"
    uci -q delete "$CONF.main.old_noresolv"
    uci -q delete "$CONF.main.old_has_resolvfile"
    uci -q delete "$CONF.main.old_resolvfile"
    uci -q delete "$CONF.main.old_has_server"
    uci -q delete "$CONF.main.old_server"
    uci -q commit "$CONF" 2>/dev/null
}

# 仅清除保存的备份值，不改动 DNSMasq 当前设置
clear_original() {
    uci -q delete "$CONF.main.old_captured"
    uci -q delete "$CONF.main.old_has_port"
    uci -q delete "$CONF.main.old_port"
    uci -q delete "$CONF.main.old_has_noresolv"
    uci -q delete "$CONF.main.old_noresolv"
    uci -q delete "$CONF.main.old_has_resolvfile"
    uci -q delete "$CONF.main.old_resolvfile"
    uci -q delete "$CONF.main.old_has_server"
    uci -q delete "$CONF.main.old_server"
    uci -q commit "$CONF" 2>/dev/null
}

# 修改 AdGuard Home 配置文件中的 DNS 端口，并确认写入成功
patch_agh_port() {
    [ -s "$configpath" ] || return 0

    yaml_set_scalar "$configpath" "port" "$dnsport" || return 1
    grep -q "^  port: $dnsport$" "$configpath" || return 1
    return 0
}

# 强制 DNSMasq 监听指定端口，并确认 UCI 实际写入成功
set_dnsmasq_port() {
    _want_port="$1"
    uci -q set "dhcp.@dnsmasq[0].port=$_want_port" || return 1
    uci -q commit dhcp 2>/dev/null || return 1
    [ "$(get_uci dhcp.@dnsmasq[0].port)" = "$_want_port" ]
}

# 接管失败时恢复 DNSMasq 并标记未应用，避免半接管导致断网
cancel_dns_mode_apply() {
    log_msg "$1"
    restore_original
    dhcp_option_restore
    dns_redirect_restore
    uci -q set "$CONF.main.mode_applied=none"
    uci -q commit "$CONF" 2>/dev/null
    return 1
}

# 接管 53 / PassWall 前置时 DNSMasq 被移到 1745，不再把自己作为 DNS 下发给 DHCP 客户端，
# 客户端会「拿到 IP 但上不了网」。这里给每个启用的 DHCP 服务段补一条 option 6，
# 指向该网段自身接口的地址；只删除自己补的那条，用户手动配置的保持不动。
# 记录格式为「段名|6,IP」，旧版本只有「6,IP」时按 lan 处理。

# 列出所有 DHCP 服务段（dnsmasq / odhcpd 段的类型不是 dhcp，不会被选中）
dhcp_sections() {
    uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.]*\)=dhcp$/\1/p'
}

# 取 DHCP 段对应接口的 IPv4 地址（该网段的网关地址）
dhcp_section_dns_ip() {
    _if="$(get_uci "dhcp.$1.interface")"
    [ -n "$_if" ] || return 0

    _ip="$(get_uci "network.$_if.ipaddr")"
    _ip="${_ip%%/*}"
    if [ -z "$_ip" ] && have_cmd jsonfilter; then
        _ip="$(ubus call "network.interface.$_if" status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
    fi
    if [ -z "$_ip" ]; then
        _dev="$(get_uci "network.$_if.device")"
        [ -n "$_dev" ] || _dev="br-$_if"
        _ip="$(ip -4 addr show dev "$_dev" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
    fi
    echo "$_ip"
}

dhcp_option_present() {
    for _o in $(get_uci "dhcp.$1.dhcp_option"); do
        [ "$_o" = "$2" ] && return 0
    done
    return 1
}

# 段内是否已有其它 6, 开头的 DNS 下发（排除指定值）
dhcp_option_has_dns() {
    _excl="$2"
    for _o in $(get_uci "dhcp.$1.dhcp_option"); do
        case "$_o" in
            6,*) [ "$_o" = "$_excl" ] || return 0 ;;
        esac
    done
    return 1
}

# 兼容旧格式：单值「6,IP」视为 lan 段
added_dhcp_pairs() {
    for _a in $(get_uci "$CONF.main.added_dhcp_option"); do
        case "$_a" in
            *'|'*) echo "$_a" ;;
            *) echo "lan|$_a" ;;
        esac
    done
}

dhcp_option_add() {
    _old_raw="$(get_uci "$CONF.main.added_dhcp_option")"
    _old="$(added_dhcp_pairs)"
    _new=""
    _changed="0"

    for _sec in $(dhcp_sections); do
        [ "$(get_uci "dhcp.$_sec.ignore")" = "1" ] && continue
        _ip="$(dhcp_section_dns_ip "$_sec")"
        [ -n "$_ip" ] || continue
        _want="6,$_ip"
        _key="$_sec|$_want"

        # 该段之前是否由插件补过
        _owned=""
        for _p in $_old; do
            case "$_p" in
                "$_sec|"*) _owned="${_p#*|}" ;;
            esac
        done

        if [ -n "$_owned" ]; then
            if [ "$_owned" = "$_want" ]; then
                # 用户后来自己配了别的 6, 选项时让位，撤掉插件补的
                if dhcp_option_has_dns "$_sec" "$_owned"; then
                    uci -q del_list "dhcp.$_sec.dhcp_option=$_owned" 2>/dev/null
                    _changed="1"
                    log_msg "检测到 $_sec 已有手动配置的 DNS 下发，已移除插件补的那条。"
                    continue
                fi
                _new="$_new $_key"
                continue
            fi
            # 该段地址变化：先撤旧值
            uci -q del_list "dhcp.$_sec.dhcp_option=$_owned" 2>/dev/null
            _changed="1"
        fi

        if dhcp_option_has_dns "$_sec" ""; then
            log_msg "检测到 $_sec 已有 DHCP DNS 下发，保持不动。"
            continue
        fi
        if dhcp_option_present "$_sec" "$_want"; then
            _new="$_new $_key"
            continue
        fi

        uci -q add_list "dhcp.$_sec.dhcp_option=$_want" || continue
        _new="$_new $_key"
        _changed="1"
        log_msg "已为 $_sec 自动下发 DNS（$_want）。"
    done

    # 清理已经不在接管范围内的旧记录（段被删除或改为不接管）
    for _p in $_old; do
        case " $_new " in *" $_p "*) continue ;; esac
        _sec="${_p%%|*}"
        _val="${_p#*|}"
        uci -q get "dhcp.$_sec" >/dev/null 2>&1 || continue
        uci -q del_list "dhcp.$_sec.dhcp_option=$_val" 2>/dev/null
        _changed="1"
    done

    # 记录没变化时不重写 UCI，避免每次应用都产生一次闪存写入；
    # 旧格式（只有 6,IP）会在这次比较中触发一次迁移写入
    if [ "$(echo $_new)" != "$(echo $_old_raw)" ]; then
        uci -q delete "$CONF.main.added_dhcp_option"
        for _p in $_new; do
            uci -q add_list "$CONF.main.added_dhcp_option=$_p"
        done
        uci -q commit "$CONF" 2>/dev/null
    fi

    if [ "$_changed" = "1" ]; then
        uci -q commit dhcp 2>/dev/null
        log_msg "已更新 DHCP DNS 下发，避免客户端拿到 IP 却无法解析。"
        restart_dnsmasq
        sleep 1
    fi
    return 0
}

dhcp_option_restore() {
    _changed="0"
    for _p in $(get_uci "$CONF.main.added_dhcp_option"); do
        case "$_p" in
            *'|'*) _sec="${_p%%|*}"; _val="${_p#*|}" ;;
            *) _sec="lan"; _val="$_p" ;;
        esac
        uci -q get "dhcp.$_sec" >/dev/null 2>&1 || continue
        uci -q del_list "dhcp.$_sec.dhcp_option=$_val" 2>/dev/null
        _changed="1"
    done
    uci -q delete "$CONF.main.added_dhcp_option"
    uci -q commit "$CONF" 2>/dev/null

    if [ "$_changed" = "1" ]; then
        uci -q commit dhcp 2>/dev/null
        log_msg "已移除插件自动下发的 DHCP DNS。"
    fi
    return 0
}

# KuWrt / iStoreOS 25.12 的 DNSMasq 内置「DNS 劫持」（dns_redirect=1）会以 -105 优先级
# 把所有 53 查询送到 DNSMasq(1745)，抢在接管规则之前，导致客户端查询绕过 AdGuard Home。
# 接管 53 / PassWall 前置时关闭它并记录，停止/切换/卸载时还原。
dns_redirect_disable() {
    [ "$(get_uci dhcp.@dnsmasq[0].dns_redirect)" = "1" ] || return 0
    uci -q set "$CONF.main.added_dns_redirect=1"
    uci -q set dhcp.@dnsmasq[0].dns_redirect=0
    uci -q commit dhcp 2>/dev/null
    uci -q commit "$CONF" 2>/dev/null
    log_msg "已关闭 DNSMasq 内置的 DNS 劫持（dns_redirect），避免客户端查询绕过 AdGuard Home。"
    restart_dnsmasq
    sleep 1
}

dns_redirect_restore() {
    [ "$(get_uci "$CONF.main.added_dns_redirect")" = "1" ] || return 0
    uci -q set dhcp.@dnsmasq[0].dns_redirect=1
    uci -q delete "$CONF.main.added_dns_redirect"
    uci -q commit dhcp 2>/dev/null
    uci -q commit "$CONF" 2>/dev/null
    log_msg "已恢复 DNSMasq 内置的 DNS 劫持（dns_redirect）。"
    restart_dnsmasq
    sleep 1
}

# 接管 53 端口模式：Clash 的 DNS 劫持会把设备的 53 查询直接拽到 DNSMasq（1745），
# 从而绕过 AdGuard Home。这里在它的 dstnat 规则之前（priority -101）再加一条
# 重定向，把局域网设备的 DNS 查询统一收回路由器 53 端口，交给 AdGuard Home 过滤。
AGH_NFT_FILE="/etc/nftables.d/30-adguardhome-lite-dns.nft"

# IPv6 仅排除 WAN 默认路由接口，其余接口（LAN/访客/IoT）全部纳入接管
agh_nft_wan_iface() {
    _if="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$_if" ] || _if="$(uci -q get network.wan.device 2>/dev/null)"
    [ -n "$_if" ] || _if="$(uci -q get network.wan.ifname 2>/dev/null)"
    [ -n "$_if" ] || _if="wan"
    echo "$_if"
}

# 只有 fw4 的 nft 表存在时才校验重定向规则；
# fw3 或没有 nft 的固件不做这项判断，避免每次应用都被误判为未生效。
agh_nft_supported() {
    have_cmd nft || return 1
    nft list table inet fw4 >/dev/null 2>&1
}

agh_nft_rule_present() {
    have_cmd nft || return 1
    _rules="$(nft list chain inet fw4 agh_dns_redirect 2>/dev/null)" || return 1
    echo "$_rules" | grep -q 'DNS Redirect v4' || return 1
    echo "$_rules" | grep -q 'DNS Redirect v6' || return 1
    # PassWall 模式不写排除规则，检查时也跳过
    [ "$dns_mode" = "passwall" ] && return 0
    # 配置了排除项就必须真的存在对应规则，否则会误判为已生效
    [ -n "$(bypass_ifaces)" ] && {
        echo "$_rules" | grep -q 'AGH bypass iface to-dnsmasq' || return 1
        echo "$_rules" | grep -q 'AGH bypass iface direct' || return 1
    }
    bypass_clients
    [ -n "$BYPASS_V4" ] && {
        echo "$_rules" | grep -q 'AGH bypass client v4 to-dnsmasq' || return 1
        echo "$_rules" | grep -q 'AGH bypass client v4 direct' || return 1
    }
    [ -n "$BYPASS_V6" ] && {
        echo "$_rules" | grep -q 'AGH bypass client v6 to-dnsmasq' || return 1
        echo "$_rules" | grep -q 'AGH bypass client v6 direct' || return 1
    }
    return 0
}

# 排除规则的 nft 片段：命中的查询直接交给 DNSMasq（接管模式下固定 1745），
# 不进入 AdGuard Home。问路由器本机的查询重定向给 DNSMasq，其余查询直接放行，
# 既不会被 Clash 的 DNS 劫持带走，也不会把排除变成另一种全局劫持。
agh_nft_bypass_lines() {
    _lines=""

    _ifs="$(bypass_ifaces)"
    if [ -n "$_ifs" ]; then
        _set=""
        for _i in $_ifs; do _set="$_set\"$_i\", "; done
        _set="${_set%, }"
        _lines="    iifname { $_set } meta l4proto { tcp, udp } th dport 53 fib daddr type local redirect to :1745 comment \"AGH bypass iface to-dnsmasq\"
    iifname { $_set } meta l4proto { tcp, udp } th dport 53 accept comment \"AGH bypass iface direct\"
"
    fi

    bypass_clients
    if [ -n "$BYPASS_V4" ]; then
        _set=""
        for _c in $BYPASS_V4; do _set="$_set$_c, "; done
        _set="${_set%, }"
        _lines="${_lines}    meta nfproto ipv4 ip saddr { $_set } meta l4proto { tcp, udp } th dport 53 fib daddr type local redirect to :1745 comment \"AGH bypass client v4 to-dnsmasq\"
    meta nfproto ipv4 ip saddr { $_set } meta l4proto { tcp, udp } th dport 53 accept comment \"AGH bypass client v4 direct\"
"
    fi
    if [ -n "$BYPASS_V6" ]; then
        _set=""
        for _c in $BYPASS_V6; do _set="$_set$_c, "; done
        _set="${_set%, }"
        _lines="${_lines}    meta nfproto ipv6 ip6 saddr { $_set } meta l4proto { tcp, udp } th dport 53 fib daddr type local redirect to :1745 comment \"AGH bypass client v6 to-dnsmasq\"
    meta nfproto ipv6 ip6 saddr { $_set } meta l4proto { tcp, udp } th dport 53 accept comment \"AGH bypass client v6 direct\"
"
    fi

    printf '%s' "$_lines"
}

agh_nft_reload() {
    # 注意：部分固件（如 iStoreOS 24.10）的 `fw4 reload` 不会重建整份规则集，
    # 必须走 /etc/init.d/firewall restart 才能让新增/删除的链真正生效。
    if [ -x /etc/init.d/firewall ]; then
        _out=$(/etc/init.d/firewall restart 2>&1)
    elif have_cmd fw4; then
        _out=$(fw4 restart 2>&1)
    else
        return 0
    fi

    if [ $? -ne 0 ]; then
        log_msg "防火墙重载失败：$(echo "$_out" | tail -n 2 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

agh_nft_ensure() {
    [ -d /etc/nftables.d ] || return 0
    have_cmd nft || return 0

    _wan="$(agh_nft_wan_iface)"
    # PassWall 模式不写排除规则：排除的客户端直接落到 PassWall 自己的劫持上，
    # 仍然走 PassWall DNS 分流，只是不经过 AdGuard Home 过滤。
    _bypass=""
    [ "$dns_mode" = "passwall" ] || _bypass="$(agh_nft_bypass_lines)"
    # PassWall 的 DNS 劫持链优先级为 -101，这里必须再靠前一位（-102），
    # 否则同一优先级下谁先生效不确定，查询可能被 PassWall 抢走。
    _prio="-101"
    [ "$dns_mode" = "passwall" ] && _prio="-102"
    _want="# AdGuard Home 管理中心：接管 53 端口时启用，避免被 Clash / PassWall 的 DNS 劫持绕过。
chain agh_dns_redirect {
    type nat hook prerouting priority $_prio; policy accept;
${_bypass}
    meta nfproto ipv4 ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } meta l4proto { tcp, udp } th dport 53 counter redirect to :53 comment \"AdGuard Home DNS Redirect v4\"
    meta nfproto ipv6 iifname != \"$_wan\" meta l4proto { tcp, udp } th dport 53 counter redirect to :53 comment \"AdGuard Home DNS Redirect v6\"
}"

    # 规则写进 /etc/nftables.d 后会被 fw4 整份加载，语法错误会直接拖垮防火墙，
    # 所以先在临时表里用 nft -c 校验，失败就保持原规则不动。
    _check="/tmp/agh_nft_check.$$"
    {
        printf 'table inet agh_check {\n'
        printf '%s\n' "$_want"
        printf '}\n'
    } > "$_check"
    if ! nft -c -f "$_check" >/dev/null 2>&1; then
        log_msg "DNS 重定向规则校验失败（排除接口或客户端写法有误），已跳过本次更新。"
        rm -f "$_check"
        return 1
    fi
    rm -f "$_check"

    _changed="0"
    if [ ! -f "$AGH_NFT_FILE" ] || [ "$(cat "$AGH_NFT_FILE")" != "$_want" ]; then
        printf '%s\n' "$_want" > "$AGH_NFT_FILE"
        _changed="1"
    fi

    # 文件变化或规则不完整时都必须重载，否则旧链不会更新
    if [ "$_changed" = "0" ] && agh_nft_rule_present; then
        return 0
    fi

    # 链已存在但声明（优先级/规则）变化时，restart 会报
    # 「Chain already exists ... with different declaration」并整份规则不重建，
    # 必须先删掉旧链，让 fw4 按新文件重新创建。
    if [ "$_changed" = "1" ]; then
        nft delete chain inet fw4 agh_dns_redirect 2>/dev/null
    fi
    agh_nft_reload
    agh_nft_rule_present && return 0

    sleep 1
    agh_nft_reload
    if ! agh_nft_rule_present; then
        log_msg "DNS 重定向规则未生效：Clash 的劫持可能仍会绕过 AdGuard Home，请检查防火墙状态。"
    fi
}

agh_nft_clear() {
    _had="0"
    [ -f "$AGH_NFT_FILE" ] && _had="1"
    rm -f "$AGH_NFT_FILE"

    # 文件删掉后链可能还留在内核里，直接删掉我们的链，避免残留空链
    if have_cmd nft && nft list chain inet fw4 agh_dns_redirect >/dev/null 2>&1; then
        nft delete chain inet fw4 agh_dns_redirect 2>/dev/null && _had="1"
    fi

    [ "$_had" = "1" ] && agh_nft_reload
    return 0
}

# 判断当前 DNSMasq 是否已经是目标模式
mode_is_applied() {
    [ "$mode_applied" = "$dns_mode" ] || return 1

    case "$dns_mode" in
        upstream)
            [ "$(dnsmasq_port)" = "53" ] || return 1
            [ "$(get_uci dhcp.@dnsmasq[0].noresolv)" = "1" ] || return 1
            echo "$(get_uci dhcp.@dnsmasq[0].server)" | grep -q '127.0.0.1#5333' || return 1
            ;;
        takeover)
            [ "$(dnsmasq_port)" = "1745" ] || return 1
            # 规则可能被防火墙重载或固件脚本清掉，缺失时重新应用，避免静默失去过滤
            agh_nft_supported && { agh_nft_rule_present || return 1; }
            ;;
        passwall)
            [ "$(dnsmasq_port)" = "1745" ] || return 1
            # 收回 53 的规则优先级必须高于 PassWall，规则缺失就重新应用
            agh_nft_supported && { agh_nft_rule_present || return 1; }
            ;;
        openclash)
            openclash_forward_present || return 1
            grep -q "^  port: $dnsport$" "$configpath" || return 1
            # DNSMasq 永远保持 53，绝不跟随劫持端口（避免与 Clash 的 7874 抢端口）
            _dp="$(get_uci dhcp.@dnsmasq[0].port)"
            [ -n "$_dp" ] || _dp="53"
            [ "$_dp" = "53" ] || return 1
            ;;
        clashfirst)
            grep -q "^  port: $dnsport$" "$configpath" || return 1
            [ "$(dnsmasq_port)" = "53" ] || return 1
            # 未安装 Clash 时无法自动写上游，只要端口正确就视为已应用
            if uci -q get openclash.config >/dev/null 2>&1; then
                [ -n "$(get_uci "$CONF.main.oc_agh_sid")" ] || return 1
            fi
            ;;
        none)
            ;;
    esac
    return 0
}

mode_name() {
    case "$dns_mode" in
        takeover) echo "接管 53 端口模式（DNSMasq 移至 1745）" ;;
        passwall) echo "PassWall 前置模式（AGH 53 → PassWall DNS 分流）" ;;
        openclash) echo "Clash 串联模式（已下线）" ;;
        clashfirst) echo "Clash 前置模式（Clash 7874 → AdGuard Home 5335 → 真实 DNS）" ;;
        none) echo "仅面板模式（不接管 DNS）" ;;
        *) echo "DNSMasq 上游模式（AdGuard Home 监听 5333）" ;;
    esac
}

apply_mode() {
    case "$dns_mode" in
        upstream|takeover|none|openclash|clashfirst|passwall) ;;
        *) dns_mode="upstream" ;;
    esac

    # 「Clash 串联」已下线：Clash 写入 dnsmasq 的默认上游排在 conf-dir 前面，
    # strict-order 下查询会被 Clash 先应答，AdGuard Home 实际收不到查询。
    if [ "$dns_mode" = "openclash" ]; then
        log_msg "「Clash 串联」模式已下线（过滤会被 Clash 抢先应答），已切换为「接管 53 端口」。"
        openclash_forward_del
        uci -q set "$CONF.main.dns_mode=takeover"
        uci -q commit "$CONF" 2>/dev/null
        dns_mode="takeover"
        dnsport="53"
    fi

    if ! uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
        log_msg "未找到 DNSMasq 配置，跳过 DNS 接管设置。"
        patch_agh_port
        uci -q set "$CONF.main.mode_applied=$dns_mode"
        uci -q commit "$CONF" 2>/dev/null
        return 0
    fi

    if [ "$dns_mode" = "takeover" ] || [ "$dns_mode" = "passwall" ]; then
        agh_nft_ensure
    else
        agh_nft_clear
    fi

    # DNSMasq 在 1745 时不会自动下发 DNS，需要给 LAN 的 DHCP 补 option 6；
    # 不再接管时只撤掉插件自己补的那条。
    case "$dns_mode" in
        takeover|passwall)
            dhcp_option_add
            dns_redirect_disable
            ;;
        *)
            dhcp_option_restore
            dns_redirect_restore
            ;;
    esac

    if mode_is_applied; then
        if ! patch_agh_port; then
            log_msg "无法写入 AdGuard Home DNS 端口，正在恢复 DNSMasq 设置..."
            revert_mode
            return 1
        fi
        log_msg "DNS 接管方式未变化：$(mode_name)，跳过 DNSMasq 修改。"
        return 0
    fi

    # 从「Clash 前置」切到其它模式时，必须先把 Clash 上游还原，
    # 否则 Clash 仍指向 AdGuard Home，而 AdGuard Home 又转给 Clash，形成查询环。
    if [ "$mode_applied" = "clashfirst" ] && [ "$dns_mode" != "clashfirst" ]; then
        clashfirst_openclash_restore
        clashfirst_openclash_refresh &
    fi

    # 先恢复原始状态，再基于原始状态应用新模式，保证来回切换不叠加。
    # Clash 串联模式不长期接管 DNSMasq 设置，因此不保存/恢复原始值。
    if [ "$dns_mode" = "openclash" ]; then
        [ "$mode_applied" = "openclash" ] || restore_original
    else
        restore_original
        save_original
    fi

    # 端口写入失败时立即取消接管，避免 DNSMasq 与 AdGuard Home 端口不一致导致断网
    if ! patch_agh_port; then
        cancel_dns_mode_apply "无法将 AdGuard Home DNS 端口写为 $dnsport，已取消本次 DNS 接管。"
        return 1
    fi

    case "$dns_mode" in
        upstream)
            if ! set_dnsmasq_port 53; then
                cancel_dns_mode_apply "无法将 DNSMasq 端口写为 53，已取消本次 DNS 接管。"
                return 1
            fi
            # 保留用户自定义的域名转发（server=/domain/ip），只把默认上游换成本机 AGH，
            # 避免像以前一样删掉所有 server 规则，影响其它服务或企业内部域名。
            _kept_servers=""
            for _s in $(get_uci dhcp.@dnsmasq[0].server); do
                case "$_s" in
                    "127.0.0.1#53"|"127.0.0.1#5333"|"127.0.0.1#$clash_dns_port"|"/#/127.0.0.1#5333"|"/./127.0.0.1#5333")
                        continue
                        ;;
                esac
                _kept_servers="$_kept_servers $_s"
            done
            uci -q delete dhcp.@dnsmasq[0].server
            for _s in $_kept_servers; do
                uci -q add_list "dhcp.@dnsmasq[0].server=$_s"
            done
            if dnsmasq_hash_rule_supported; then
                uci -q add_list 'dhcp.@dnsmasq[0].server=/#/127.0.0.1#5333'
            else
                uci -q add_list 'dhcp.@dnsmasq[0].server=/./127.0.0.1#5333'
            fi
            uci -q set dhcp.@dnsmasq[0].noresolv=1
            ;;
        takeover)
            if ! set_dnsmasq_port 1745; then
                cancel_dns_mode_apply "无法将 DNSMasq 端口写为 1745，已取消本次 DNS 接管。"
                return 1
            fi
            ;;
        passwall)
            # 与「接管 53 端口」相同：DNSMasq 让出 53 移到 1745，
            # AdGuard Home 占用 53，上游指向 PassWall 自己的 DNS 做分流。
            if ! set_dnsmasq_port 1745; then
                cancel_dns_mode_apply "无法将 DNSMasq 端口写为 1745，已取消本次 DNS 接管。"
                return 1
            fi
            if ! passwall_enabled; then
                log_msg "PassWall 未启用：查询会经 AdGuard Home 转给本机 DNSMasq（1745），不走 PassWall 分流。"
            fi
            ;;
        openclash)
            # 保留 Clash 的 53 劫持，但 DNSMasq 必须留在 53：
            # 这样即使 Clash 重启/更新导致劫持规则消失，客户端仍有 DNS。
            if ! openclash_forward_add; then
                log_msg "无法写入 DNSMasq 转发规则，已取消 Clash 串联模式。"
                restore_original
                uci -q set "$CONF.main.mode_applied=none"
                uci -q commit "$CONF" 2>/dev/null
                return 1
            fi
            ensure_safe_dnsmasq_layout
            ;;
        clashfirst)
            if ! set_dnsmasq_port 53; then
                cancel_dns_mode_apply "无法将 DNSMasq 端口写为 53，已取消本次 DNS 接管。"
                return 1
            fi
            _oc_rc=0
            clashfirst_openclash_apply || _oc_rc=$?
            case "$_oc_rc" in
                0) log_msg "已将 Clash 自定义上游 DNS 设为 127.0.0.1:$dnsport" ;;
                2) log_msg "未检测到 Clash：请手动把 Clash 上游 DNS 设为 127.0.0.1:$dnsport" ;;
                3) log_msg "当前 Clash 不支持自定义上游：请手动把上游 DNS 设为 127.0.0.1:$dnsport" ;;
                *) log_msg "写入 Clash 上游失败：请手动把上游 DNS 设为 127.0.0.1:$dnsport" ;;
            esac

            # 前置模式不改 DNSMasq 转发，只需确保它留在 53
            ensure_clashfirst_chain
            ;;
        none)
            ;;
    esac

    uci -q commit dhcp 2>/dev/null
    uci -q set "$CONF.main.mode_applied=$dns_mode"
    uci -q commit "$CONF" 2>/dev/null

    restart_dnsmasq
    log_msg "已应用 $(mode_name)"
    return 0
}

# 保证 DNSMasq 监听 53，唯一例外是 Clash 仍把 53 劫持到某个端口：
# 此时若该端口空闲或由 DNSMasq 占用，就允许 DNSMasq 留在该端口，让劫持链路继续可用。
# 如果劫持目标是 Clash 自己的监听端口，则 DNSMasq 仍回到 53，由 Clash 直接应答。
ensure_safe_dnsmasq_layout() {
    _hj="$(openclash_hijack_port)"
    _cur="$(get_uci dhcp.@dnsmasq[0].port)"
    _bp="0"

    if [ -n "$_hj" ] && [ "$_hj" != "53" ] && [ "$_cur" = "$_hj" ]; then
        # Clash 劫持目标正好由 DNSMasq 监听：这是可用布局，不能把它挪回 53
        :
    elif [ "$_cur" != "53" ]; then
        uci -q set dhcp.@dnsmasq[0].port=53
        uci -q commit dhcp 2>/dev/null
        restart_dnsmasq
        sleep 1
        _cur="53"
        log_msg "DNSMasq 已恢复监听 53。"
    fi

    if [ -z "$_hj" ]; then
        log_msg "未检测到 Clash DNS 劫持，DNSMasq 转发规则生效（53 → AdGuard Home）。"
    elif [ "$_hj" = "53" ] || [ "$_hj" = "$dnsport" ]; then
        log_msg "Clash 劫持目标为 $_hj，链路正常。"
    elif [ "$_cur" = "$_hj" ]; then
        log_msg "Clash 把 53 劫持到 $_hj，DNSMasq 在该端口提供服务，解析链路正常。"
    else
        _bp="1"
        log_event warn dns_hijack_conflict "Clash 把 53 直接劫持到 $_hj，查询不再经过 DNSMasq，AdGuard Home 会被绕过。"
        if [ "$_hj" = "$clash_dns_port" ]; then
            log_msg "建议改用「Clash 前置」模式：让 Clash 把上游 DNS 交给 AdGuard Home。"
        fi
    fi

    uci -q set "$CONF.main.agh_bypassed=$_bp"
    uci -q commit "$CONF" 2>/dev/null
}

# Clash 前置模式：检查 Clash 的 DNS 劫持是否开启，
# 未开启时客户端查询不会经过 Clash，AdGuard Home 自然收不到查询。
ensure_clashfirst_chain() {
    _rd="$(get_uci openclash.config.enable_redirect_dns)"
    _bp="0"
    if [ -z "$_rd" ] || [ "$_rd" = "0" ]; then
        _bp="1"
        log_msg "Clash DNS 劫持未开启：请在 Clash 中开启 DNS 劫持，否则查询会绕过 AdGuard Home。"
    fi

    uci -q set "$CONF.main.agh_bypassed=$_bp"
    uci -q commit "$CONF" 2>/dev/null
}

# 恢复后检查上游是否可用：指向已停止的本地端口时自动回退，避免 DNSMasq 无法解析。
repair_dnsmasq_upstream() {
    [ "$(get_uci dhcp.@dnsmasq[0].noresolv)" = "1" ] || return 0

    _servers="$(get_uci dhcp.@dnsmasq[0].server)"
    [ -n "$_servers" ] || return 0

    _alive=0
    for _s in $_servers; do
        case "$_s" in
            127.0.0.1#*|::1#*|localhost#*)
                _p="${_s##*#}"
                port_listening "$_p" && _alive=1
                ;;
            *)
                _alive=1
                ;;
        esac
        [ "$_alive" = "1" ] && break
    done
    [ "$_alive" = "1" ] && return 0

    if port_listening "$clash_dns_port"; then
        log_msg "DNSMasq 上游不可用（$_servers），已切换为 Clash DNS。"
        uci -q delete dhcp.@dnsmasq[0].server
        uci -q add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$clash_dns_port"
    else
        log_msg "DNSMasq 上游不可用（$_servers），已回退到 WAN DNS。"
        uci -q delete dhcp.@dnsmasq[0].server
        uci -q set dhcp.@dnsmasq[0].noresolv=0
        if [ -s /tmp/resolv.conf.d/resolv.conf.auto ]; then
            uci -q set dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.d/resolv.conf.auto
        else
            uci -q delete dhcp.@dnsmasq[0].resolvfile
        fi
    fi

    uci -q commit dhcp 2>/dev/null
    restart_dnsmasq
    sleep 1
}

# 端口是否被 DNSMasq 以外的进程占用（空闲或由 DNSMasq 占用都返回 1）
port_held_by_other() {
    _pho_port="$1"
    [ -n "$_pho_port" ] || return 1
    netstat -lnptu 2>/dev/null \
        | awk -v p=":$_pho_port" '$4 ~ (p "$") {print $NF}' \
        | grep -v 'dnsmasq' | grep -q .
}

revert_mode() {
    _had="$(get_uci "$CONF.main.old_captured")"
    _applied="$(get_uci "$CONF.main.mode_applied")"
    _oc="0"
    openclash_forward_present && _oc="1"
    _old_port="$(get_uci dhcp.@dnsmasq[0].port)"

    # 停止服务或切换模式后不再接管 53，移除自建的重定向规则
    agh_nft_clear

    # 只移除插件自己补的 DHCP DNS 下发，用户手动配置的保持不动
    dhcp_option_restore
    dns_redirect_restore

    if [ "$_applied" = "clashfirst" ]; then
        clashfirst_openclash_restore
    fi

    if [ "$_applied" = "openclash" ]; then
        # 串联模式未接管 DNSMasq：只移除转发规则并清理可能遗留的备份记录。
        openclash_forward_del
        clear_original
    else
        restore_original
        openclash_forward_del
    fi

    uci -q set "$CONF.main.mode_applied=none"
    uci -q commit "$CONF" 2>/dev/null

    # Clash 劫持仍指向原接管端口时，保持 DNSMasq 在该端口，避免恢复后断 DNS
    _hj2="$(openclash_hijack_port)"
    if [ -n "$_hj2" ] && [ "$_hj2" != "53" ] && ! port_held_by_other "$_hj2"; then
        if set_dnsmasq_port "$_hj2"; then
            log_msg "检测到 Clash 劫持目标为 $_hj2，DNSMasq 监听该端口以维持解析。"
        else
            log_msg "无法把 DNSMasq 调整到 Clash 劫持端口 $_hj2，请检查 DNSMasq 状态。"
        fi
    fi

    # 保证 53 端口始终有 DNS 服务：
    # - DNSMasq 必须留在 53（有劫持时也不再跟随劫持端口）；
    # - 如果 Clash 已停止，53 仍由 DNSMasq 提供服务，避免客户端无 DNS。
    ensure_safe_dnsmasq_layout

    # 关闭插件后不再有“被绕过”状态，避免面板残留提示
    uci -q set "$CONF.main.agh_bypassed=0"
    uci -q commit "$CONF" 2>/dev/null

    if [ "$_applied" = "clashfirst" ]; then
        # 恢复 Clash 上游后需要重载，否则 Clash 仍指向已停止的 5335
        clashfirst_openclash_refresh &
    fi

    _new_port="$(get_uci dhcp.@dnsmasq[0].port)"
    if [ "$_had" = "1" ] || [ "$_oc" = "1" ] || [ "$_old_port" != "$_new_port" ]; then
        restart_dnsmasq
        sleep 1
        # 恢复后如果上游指向已停止的本地端口，自动回退到 WAN DNS，避免断网
        repair_dnsmasq_upstream
        # 按 DNSMasq 实际端口自检：Clash 劫持布局下 DNSMasq 可能不在 53
        _chk_port="$(get_uci dhcp.@dnsmasq[0].port)"
        [ -n "$_chk_port" ] || _chk_port="53"
        if ! nslookup -timeout=2 -retry=1 -port="$_chk_port" www.baidu.com 127.0.0.1 >/dev/null 2>&1; then
            log_event warn dns_revert_failed "DNSMasq（端口 $_chk_port）解析仍失败，请检查 Clash 运行状态或 WAN DNS。"
        fi
        log_msg "已恢复 DNSMasq 原始设置"
    fi
}

show_status() {
    echo "dns_mode=$dns_mode"
    echo "mode_applied=$mode_applied"
    echo "agh_dns_port=$dnsport"
    echo "dnsmasq_port=$(get_uci dhcp.@dnsmasq[0].port)"
    echo "dnsmasq_noresolv=$(get_uci dhcp.@dnsmasq[0].noresolv)"
    echo "dnsmasq_server=$(get_uci dhcp.@dnsmasq[0].server)"
    echo "lan_dhcp_option=$(get_uci dhcp.lan.dhcp_option)"
    echo "added_dhcp_option=$(get_uci "$CONF.main.added_dhcp_option")"
    echo "dnsmasq_dns_redirect=$(get_uci dhcp.@dnsmasq[0].dns_redirect)"
    echo "added_dns_redirect=$(get_uci "$CONF.main.added_dns_redirect")"
    echo "clash_dns_port=$clash_dns_port"
    echo "openclash_hijack_port=$(openclash_hijack_port)"
    echo "openclash_redirect=$(get_uci openclash.config.enable_redirect_dns)"
    echo "openclash_custom_dns=$(get_uci openclash.config.enable_custom_dns)"
    echo "agh_bypassed=$(get_uci "$CONF.main.agh_bypassed")"
    echo "openclash_forward=$(openclash_forward_present && echo yes || echo no)"
    echo "passwall_enabled=$(passwall_enabled && echo yes || echo no)"
    if [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null)" = "1" ]; then
        echo "passwall_dns_redirect=$(get_uci passwall2.@global[0].dns_redirect)"
    else
        echo "passwall_dns_redirect=$(get_uci passwall.@global[0].dns_redirect)"
    fi
    echo "passwall_dns_port=$(passwall_dns_port)"
}

case "$ACTION" in
    apply) apply_mode ;;
    revert) revert_mode ;;
    status) show_status ;;
    *)
        echo "用法：$0 apply|revert|status"
        exit 1
        ;;
esac

exit 0
