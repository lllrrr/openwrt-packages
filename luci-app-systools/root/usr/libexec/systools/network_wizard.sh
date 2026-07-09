#!/bin/sh
# 网络向导后端脚本
# 支持 PPPoE、DHCP、静态 IP 三种上网方式
# 自动备份，失败回滚

BACKUP_DIR="/tmp/systools_backup"
BACKUP_FILE="$BACKUP_DIR/network_$(date +%Y%m%d_%H%M%S).tar.gz"
LATEST_BACKUP="$BACKUP_DIR/network_latest.tar.gz"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 备份网络配置
backup_network() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # 备份 network 配置
    uci export network > "$tmpdir/network.uci" 2>/dev/null

    # 备份 firewall 配置
    uci export firewall > "$tmpdir/firewall.uci" 2>/dev/null

    # 备份 dhcp 配置
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
restore_network() {
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

    # 恢复 network
    if [ -f "$tmpdir/network.uci" ]; then
        uci import network < "$tmpdir/network.uci" 2>/dev/null
    fi

    # 恢复 firewall
    if [ -f "$tmpdir/firewall.uci" ]; then
        uci import firewall < "$tmpdir/firewall.uci" 2>/dev/null
    fi

    # 恢复 dhcp
    if [ -f "$tmpdir/dhcp.uci" ]; then
        uci import dhcp < "$tmpdir/dhcp.uci" 2>/dev/null
    fi

    uci commit

    rm -rf "$tmpdir"

    echo "Restored from: $backup_file"
    return 0
}

# 获取当前状态
get_status() {
    local wan_proto
    wan_proto=$(uci get network.wan.proto 2>/dev/null)

    local connected="no"
    if [ -n "$(ip route show default 2>/dev/null)" ]; then
        connected="yes"
    fi

    local lan_ip
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)

    echo "wan_proto=$wan_proto"
    echo "connected=$connected"
    echo "lan_ip=$lan_ip"
}

# 应用 PPPoE 配置
apply_pppoe() {
    local username="$1"
    local password="$2"

    if [ -z "$username" ] || [ -z "$password" ]; then
        echo "Error: username and password required"
        return 1
    fi

    # 先备份
    backup_network || return 1

    # 配置 WAN 为 PPPoE
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$username"
    uci set network.wan.password="$password"

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "PPPoE configuration applied"
    return 0
}

# 应用 DHCP 配置
apply_dhcp() {
    # 先备份
    backup_network || return 1

    # 配置 WAN 为 DHCP
    uci set network.wan.proto='dhcp'

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "DHCP configuration applied"
    return 0
}

# 应用静态 IP 配置
apply_static() {
    local ipaddr="$1"
    local gateway="$2"
    local netmask="$3"
    local dns="$4"

    if [ -z "$ipaddr" ] || [ -z "$gateway" ]; then
        echo "Error: IP address and gateway required"
        return 1
    fi

    # 默认子网掩码
    if [ -z "$netmask" ]; then
        netmask="255.255.255.0"
    fi

    # 先备份
    backup_network || return 1

    # 配置 WAN 为静态 IP
    uci set network.wan.proto='static'
    uci set network.wan.ipaddr="$ipaddr"
    uci set network.wan.netmask="$netmask"
    uci set network.wan.gateway="$gateway"

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    # 设置 DNS
    if [ -n "$dns" ]; then
        uci set network.wan.dns="$dns"
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    echo "Static IP configuration applied"
    return 0
}

# 主入口
case "$1" in
    status)
        get_status
        ;;
    backup)
        backup_network
        ;;
    restore)
        restore_network "$2"
        ;;
    pppoe)
        apply_pppoe "$2" "$3"
        ;;
    dhcp)
        apply_dhcp
        ;;
    static)
        apply_static "$2" "$3" "$4" "$5"
        ;;
    *)
        echo "Usage: $0 {status|backup|restore|pppoe|dhcp|static}"
        echo ""
        echo "Commands:"
        echo "  status              Show current network status"
        echo "  backup              Backup network configuration"
        echo "  restore [file]      Restore from backup (latest if not specified)"
        echo "  pppoe <user> <pass> Configure PPPoE connection"
        echo "  dhcp                Configure DHCP connection"
        echo "  static <ip> <gw> [mask] [dns]  Configure static IP"
        exit 1
        ;;
esac
