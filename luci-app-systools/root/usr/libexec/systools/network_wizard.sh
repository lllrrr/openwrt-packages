#!/bin/sh
# 网络向导后端脚本
# 支持 PPPoE、DHCP、静态 IP 三种上网方式
# 支持高级设置：MAC 地址克隆、MTU、DNS 自定义
# 自动备份，失败回滚

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

BACKUP_DIR="/etc/systools/backup/network"
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
    local wan_mac
    wan_mac=$(uci get network.wan.macaddr 2>/dev/null)
    local wan_mtu
    wan_mtu=$(uci get network.wan.mtu 2>/dev/null)
    echo "wan_proto=$wan_proto"
    echo "connected=$connected"
    echo "lan_ip=$lan_ip"
    echo "wan_mac=$wan_mac"
    echo "wan_mtu=$wan_mtu"
}

# 解析高级参数（key=value 格式）
# 全局变量保存解析结果
ADV_MAC=""
ADV_MTU=""
ADV_DNS1=""
ADV_DNS2=""

parse_advanced_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            mac=*)
                ADV_MAC="${1#mac=}"
                ;;
            mtu=*)
                ADV_MTU="${1#mtu=}"
                ;;
            dns1=*)
                ADV_DNS1="${1#dns1=}"
                ;;
            dns2=*)
                ADV_DNS2="${1#dns2=}"
                ;;
        esac
        shift
    done
}

# 应用高级设置（MAC、MTU、DNS）
apply_advanced_settings() {
    # MAC 地址克隆
    if [ -n "$ADV_MAC" ]; then
        if ! is_valid_mac "$ADV_MAC"; then
            log_error "Invalid MAC address format: $ADV_MAC"
            return 1
        fi
        uci set network.wan.macaddr="$ADV_MAC"
    fi

    # MTU 设置
    if [ -n "$ADV_MTU" ]; then
        if ! echo "$ADV_MTU" | grep -qE '^[0-9]+$' || [ "$ADV_MTU" -lt 576 ] || [ "$ADV_MTU" -gt 9000 ]; then
            log_error "Invalid MTU value: $ADV_MTU (must be 576-9000)"
            return 1
        fi
        uci set network.wan.mtu="$ADV_MTU"
    fi

    # DNS 设置
    local dns_list=""
    if [ -n "$ADV_DNS1" ]; then
        dns_list="$ADV_DNS1"
    fi
    if [ -n "$ADV_DNS2" ]; then
        if [ -n "$dns_list" ]; then
            dns_list="$dns_list $ADV_DNS2"
        else
            dns_list="$ADV_DNS2"
        fi
    fi
    if [ -n "$dns_list" ]; then
        uci set network.wan.dns="$dns_list"
        # 同时设置 peerdns=0 防止 DHCP/PPPoE 覆盖 DNS
        uci set network.wan.peerdns='0'
    fi
}

# 应用 PPPoE 配置
apply_pppoe() {
    local username="$1"
    local password="$2"
    shift 2  # 移除前两个参数，剩下的是高级参数

    if [ -z "$username" ] || [ -z "$password" ]; then
        log_error "username and password required"
        return 1
    fi

    # 获取并发锁
    if ! acquire_lock "network_config"; then
        log_error "Another network configuration operation is in progress"
        return 1
    fi

    # 解析高级参数
    parse_advanced_args "$@"

    # 先备份
    if ! backup_network; then
        release_lock "network_config"
        return 1
    fi

    # 配置 WAN 为 PPPoE
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$username"
    uci set network.wan.password="$password"

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    # 应用高级设置
    if ! apply_advanced_settings; then
        release_lock "network_config"
        return 1
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    release_lock "network_config"
    echo "PPPoE configuration applied"
    return 0
}

# 应用 DHCP 配置
apply_dhcp() {
    # 获取并发锁
    if ! acquire_lock "network_config"; then
        log_error "Another network configuration operation is in progress"
        return 1
    fi

    # 解析高级参数
    parse_advanced_args "$@"

    # 先备份
    if ! backup_network; then
        release_lock "network_config"
        return 1
    fi

    # 配置 WAN 为 DHCP
    uci set network.wan.proto='dhcp'

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    # 应用高级设置
    if ! apply_advanced_settings; then
        release_lock "network_config"
        return 1
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    release_lock "network_config"
    echo "DHCP configuration applied"
    return 0
}

# 应用静态 IP 配置
apply_static() {
    local ipaddr="$1"
    local gateway="$2"
    local netmask="$3"
    local dns="$4"
    shift 4  # 移除前四个参数，剩下的是高级参数

    if [ -z "$ipaddr" ] || [ -z "$gateway" ]; then
        log_error "IP address and gateway required"
        return 1
    fi

    # 参数格式二次校验
    if ! is_valid_ip "$ipaddr"; then
        log_error "Invalid IP address format: $ipaddr"
        return 1
    fi
    if ! is_valid_ip "$gateway"; then
        log_error "Invalid gateway address format: $gateway"
        return 1
    fi
    if [ -n "$netmask" ] && ! echo "$netmask" | grep -qE "^([0-9]{1,3}\.){3}[0-9]{1,3}$"; then
        log_error "Invalid netmask format: $netmask"
        return 1
    fi
    if [ -n "$dns" ] && ! is_valid_ip "$dns"; then
        log_error "Invalid DNS address format: $dns"
        return 1
    fi

    # 默认子网掩码
    if [ -z "$netmask" ]; then
        netmask="255.255.255.0"
    fi

    # 获取并发锁
    if ! acquire_lock "network_config"; then
        log_error "Another network configuration operation is in progress"
        return 1
    fi

    # 解析高级参数
    parse_advanced_args "$@"

    # 先备份
    if ! backup_network; then
        release_lock "network_config"
        return 1
    fi

    # 配置 WAN 为静态 IP
    uci set network.wan.proto='static'
    uci set network.wan.ipaddr="$ipaddr"
    uci set network.wan.netmask="$netmask"
    uci set network.wan.gateway="$gateway"

    # 确保 WAN 口是 eth0 或默认
    if ! uci get network.wan.device >/dev/null 2>&1; then
        uci set network.wan.device='eth0'
    fi

    # 设置 DNS（优先用高级参数里的，其次用旧参数）
    if [ -z "$ADV_DNS1" ] && [ -n "$dns" ]; then
        ADV_DNS1="$dns"
    fi

    # 应用高级设置
    if ! apply_advanced_settings; then
        release_lock "network_config"
        return 1
    fi

    uci commit network

    # 重启网络
    /etc/init.d/network restart 2>/dev/null &

    release_lock "network_config"
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
        apply_pppoe "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    dhcp)
        apply_dhcp "$2" "$3" "$4" "$5"
        ;;
    static)
        apply_static "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
        ;;
    *)
        echo "Usage: $0 {status|backup|restore|pppoe|dhcp|static}"
        echo ""
        echo "Commands:"
        echo "  status              Show current network status"
        echo "  backup              Backup network configuration"
        echo "  restore [file]      Restore from backup (latest if not specified)"
        echo "  pppoe <user> <pass> [mac=xx] [mtu=xx] [dns1=xx] [dns2=xx]"
        echo "  dhcp                [mac=xx] [mtu=xx] [dns1=xx] [dns2=xx]"
        echo "  static <ip> <gw> [mask] [dns]  Configure static IP"
        exit 1
        ;;
esac
