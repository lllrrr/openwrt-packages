#!/bin/sh
# IPv6 一键设置后端脚本
# 支持多种 IPv6 模式：Native、6to4、6in4、Relay、禁用
# 自动备份，失败回滚

BACKUP_DIR="/etc/systools/backup"
BACKUP_FILE="$BACKUP_DIR/ipv6_$(date +%Y%m%d_%H%M%S).tar.gz"
LATEST_BACKUP="$BACKUP_DIR/ipv6_latest.tar.gz"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 备份 IPv6 相关配置
backup_config() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # 备份 network 配置
    uci export network > "$tmpdir/network.uci" 2>/dev/null

    # 备份 dhcp 配置（IPv6 相关）
    uci export dhcp > "$tmpdir/dhcp.uci" 2>/dev/null

    # 打包
    tar -czf "$BACKUP_FILE" -C "$tmpdir" . 2>/dev/null
    cp "$BACKUP_FILE" "$LATEST_BACKUP"

    rm -rf "$tmpdir"

    if [ -f "$BACKUP_FILE" ]; then
        echo "Backup saved: $BACKUP_FILE"
        return 0
    else
        echo "Backup failed"
        return 1
    fi
}

# 从备份恢复
restore_config() {
    local backup_file="$1"

    if [ -z "$backup_file" ]; then
        backup_file="$LATEST_BACKUP"
    fi

    if [ ! -f "$backup_file" ]; then
        echo "No backup found"
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)

    tar -xzf "$backup_file" -C "$tmpdir" 2>/dev/null

    # 恢复配置
    if [ -f "$tmpdir/network.uci" ]; then
        uci import network < "$tmpdir/network.uci" 2>/dev/null
    fi
    if [ -f "$tmpdir/dhcp.uci" ]; then
        uci import dhcp < "$tmpdir/dhcp.uci" 2>/dev/null
    fi

    uci commit

    rm -rf "$tmpdir"

    echo "Restored from: $backup_file"
    return 0
}

# 获取当前 IPv6 状态
get_status() {
    local mode="disabled"
    local wan6_proto
    wan6_proto=$(uci get network.wan6.proto 2>/dev/null)

    case "$wan6_proto" in
        dhcpv6) mode="native" ;;
        6to4)   mode="6to4" ;;
        6in4)   mode="6in4" ;;
        relay)  mode="relay" ;;
    esac

    local connected="no"
    if [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
        connected="yes"
    fi

    local wan_ip
    wan_ip=$(ip -6 addr show wan6 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}' | head -1)

    local lan_prefix
    lan_prefix=$(uci get network.globals.ula_prefix 2>/dev/null)

    echo "mode=$mode"
    echo "connected=$connected"
    echo "wan_ip=$wan_ip"
    echo "lan_prefix=$lan_prefix"
}

# 配置 Native IPv6（DHCPv6 + PD）
apply_native() {
    # 先备份
    backup_config || return 1

    # 创建或修改 wan6 接口
    uci set network.wan6='interface'
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='@wan'
    uci set network.wan6.reqaddress='try'
    uci set network.wan6.reqprefix='auto'
    uci set network.wan6.ifaceid='::1'

    # 配置 LAN 口 IPv6
    uci set network.lan.ip6assign='60'
    uci set network.lan.ip6hint='10'

    # 配置 DHCPv6
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.ra_management='1'

    uci commit network
    uci commit dhcp

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "Native IPv6 (DHCPv6 + PD) enabled"
    return 0
}

# 配置 6to4 隧道
apply_6to4() {
    # 先备份
    backup_config || return 1

    # 创建 6to4 接口
    uci set network.wan6='interface'
    uci set network.wan6.proto='6to4'
    uci set network.wan6.device='@wan'

    # 配置 LAN 口 IPv6
    uci set network.lan.ip6assign='60'

    # 配置 DHCPv6
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra='server'

    uci commit network
    uci commit dhcp

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "6to4 tunnel enabled"
    return 0
}

# 配置 6in4 隧道
apply_6in4() {
    local peeraddr="$1"
    local ip6addr="$2"
    local ip6prefix="$3"
    local tunnelid="$4"
    local username="$5"
    local password="$6"

    if [ -z "$peeraddr" ]; then
        echo "Error: peer address required"
        return 1
    fi

    # 先备份
    backup_config || return 1

    # 创建 6in4 接口
    uci set network.wan6='interface'
    uci set network.wan6.proto='6in4'
    uci set network.wan6.peeraddr="$peeraddr"

    if [ -n "$ip6addr" ]; then
        uci set network.wan6.ip6addr="$ip6addr"
    fi
    if [ -n "$ip6prefix" ]; then
        uci set network.wan6.ip6prefix="$ip6prefix"
    fi
    if [ -n "$tunnelid" ]; then
        uci set network.wan6.tunnelid="$tunnelid"
    fi
    if [ -n "$username" ]; then
        uci set network.wan6.username="$username"
    fi
    if [ -n "$password" ]; then
        uci set network.wan6.password="$password"
    fi

    # 配置 LAN 口 IPv6
    uci set network.lan.ip6assign='60'

    # 配置 DHCPv6
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra='server'

    uci commit network
    uci commit dhcp

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "6in4 tunnel enabled"
    return 0
}

# 配置中继模式
apply_relay() {
    # 先备份
    backup_config || return 1

    # 创建 wan6 接口
    uci set network.wan6='interface'
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='@wan'
    uci set network.wan6.reqaddress='none'
    uci set network.wan6.reqprefix='no'

    # 配置 LAN 口 IPv6 中继
    uci set network.lan.ip6assign='60'

    # 配置 DHCPv6 中继
    uci set dhcp.lan.dhcpv6='relay'
    uci set dhcp.lan.ra='relay'
    uci set dhcp.wan='dhcp'
    uci set dhcp.wan.interface='wan'
    uci set dhcp.wan.dhcpv6='relay'
    uci set dhcp.wan.ra='relay'
    uci set dhcp.wan.master='1'

    uci commit network
    uci commit dhcp

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "IPv6 relay mode enabled"
    return 0
}

# 禁用 IPv6
apply_disabled() {
    # 先备份
    backup_config || return 1

    # 删除 wan6 接口
    uci delete network.wan6 2>/dev/null

    # 禁用 LAN 口 IPv6
    uci delete network.lan.ip6assign 2>/dev/null

    # 禁用 DHCPv6
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='disabled'

    # 禁用 IPv6 转发
    uci set firewall.@defaults[0].forward='REJECT'
    uci delete firewall.@defaults[0].ip6tables 2>/dev/null

    uci commit network
    uci commit dhcp
    uci commit firewall

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &
    /etc/init.d/firewall restart 2>/dev/null &

    echo "IPv6 disabled"
    return 0
}

# 主入口
case "$1" in
    status)
        get_status
        ;;
    backup)
        backup_config
        ;;
    restore)
        restore_config "$2"
        ;;
    native)
        apply_native
        ;;
    6to4)
        apply_6to4
        ;;
    6in4)
        apply_6in4 "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    relay)
        apply_relay
        ;;
    disabled)
        apply_disabled
        ;;
    *)
        echo "Usage: $0 {status|backup|restore|native|6to4|6in4|relay|disabled}"
        echo ""
        echo "Commands:"
        echo "  status              Show current IPv6 status"
        echo "  backup              Backup IPv6 configuration"
        echo "  restore [file]      Restore from backup"
        echo "  native              Enable Native IPv6 (DHCPv6 + PD)"
        echo "  6to4                Enable 6to4 tunnel"
        echo "  6in4 <peer> [ip6] [prefix] [id] [user] [pass]  Enable 6in4 tunnel"
        echo "  relay               Enable IPv6 relay mode"
        echo "  disabled            Disable IPv6 completely"
        exit 1
        ;;
esac
