#!/bin/sh
# 旁路由模式切换脚本
# 自动检测网络环境，一键切换旁路由模式

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh
# 自动备份，失败回滚

BACKUP_DIR="/etc/systools/backup/side_route"
BACKUP_FILE="BACKUP_DIR/side_route_$(date +%Y%m%d_%H%M%S).tar.gz"
LATEST_BACKUP="BACKUP_DIR/side_route_latest.tar.gz"
MODE_FILE="/etc/systools/side_route_mode"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 备份完整网络配置
backup_config() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # 备份所有相关配置
    uci export network > "$tmpdir/network.uci" 2>/dev/null
    uci export firewall > "$tmpdir/firewall.uci" 2>/dev/null
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
    if [ -f "$tmpdir/firewall.uci" ]; then
        uci import firewall < "$tmpdir/firewall.uci" 2>/dev/null
    fi
    if [ -f "$tmpdir/dhcp.uci" ]; then
        uci import dhcp < "$tmpdir/dhcp.uci" 2>/dev/null
    fi

    uci commit

    rm -rf "$tmpdir"

    # 删除模式标记
    rm -f "$MODE_FILE"

    echo "Restored from: $backup_file"
    return 0
}

# 获取当前状态
get_status() {
    local lan_ip
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)

    local gateway
    gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)

    local dhcp_enabled
    dhcp_enabled=$(uci get dhcp.lan.ignore 2>/dev/null)
    if [ "$dhcp_enabled" = "1" ]; then
        dhcp_enabled="no"
    else
        dhcp_enabled="yes"
    fi

    local masq_status
    masq_status=$(uci get firewall.@zone[1].masq 2>/dev/null)
    if [ "$masq_status" = "1" ]; then
        masq_status="enabled"
    else
        masq_status="disabled"
    fi

    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [ "$ip_forward" = "1" ]; then
        ip_forward="enabled"
    else
        ip_forward="disabled"
    fi

    local mode="normal"
    if [ -f "$MODE_FILE" ]; then
        mode="side_route"
    fi

    echo "mode=$mode"
    echo "lan_ip=$lan_ip"
    echo "gateway=$gateway"
    echo "dhcp_enabled=$dhcp_enabled"
    echo "masq_status=$masq_status"
    echo "ip_forward=$ip_forward"
}

# 检测当前网络环境
detect_network() {
    local lan_ip
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)

    local gateway
    gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)

    local dns
    dns=$(uci get network.wan.dns 2>/dev/null | awk '{print $1}')
    if [ -z "$dns" ]; then
        dns="$gateway"
    fi

    echo "lan_ip=$lan_ip"
    echo "gateway=$gateway"
    echo "dns=$dns"
}

# 切换到旁路由模式
enable_side_route() {
    # 先备份
    backup_config || return 1

    # 检测当前网络
    local lan_ip gateway dns
    eval $(detect_network)

    if [ -z "$lan_ip" ] || [ -z "$gateway" ]; then
        log_error "Cannot detect network configuration"
        return 1
    fi

    echo "Detected: LAN IP=$lan_ip, Gateway=$gateway, DNS=$dns"

    # 1. 关闭 WAN 口（设为 none）
    uci set network.wan.proto='none'
    uci set network.wan.auto='0'

    # 2. 关闭 DHCPv4 服务器
    uci set dhcp.lan.ignore='1'

    # 3. 关闭 DHCPv6 服务器
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='disabled'

    # 4. 设置默认网关（通过 LAN 口）
    uci set network.lan.gateway="$gateway"
    uci set network.lan.dns="$dns"

    # 5. 关闭 WAN 口的 IP 伪装（masquerade），避免双重 NAT
    # 旁路由模式下，主路由已经做了 NAT，不需要再做一次
    uci set firewall.@zone[1].masq='0'

    # 6. 确保 IP 转发开启（旁路由必须开启才能转发流量）
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    uci set firewall.@defaults[0].forward='ACCEPT'
    uci set firewall.@defaults[0].syn_flood='0'

    uci commit network
    uci commit dhcp
    uci commit firewall

    # 标记模式
    echo "side_route" > "$MODE_FILE"

    # 重启网络和防火墙
    /etc/init.d/network restart 2>/dev/null &
    /etc/init.d/firewall restart 2>/dev/null &
    /etc/init.d/dnsmasq restart 2>/dev/null &

    echo "Side route mode enabled"
    echo "LAN IP: $lan_ip"
    echo "Gateway: $gateway"
    echo "DHCP: disabled"
    return 0
}

# 恢复正常模式
disable_side_route() {
    if [ ! -f "$LATEST_BACKUP" ]; then
        log_error "No backup found, cannot restore"
        return 1
    fi

    restore_config "$LATEST_BACKUP"

    # 重启服务
    /etc/init.d/network restart 2>/dev/null &
    /etc/init.d/firewall restart 2>/dev/null &
    /etc/init.d/dnsmasq restart 2>/dev/null &

    echo "Normal router mode restored"
    return 0
}

# 主入口
case "$1" in
    status)
        get_status
        ;;
    detect)
        detect_network
        ;;
    backup)
        backup_config
        ;;
    restore)
        restore_config "$2"
        ;;
    enable)
        enable_side_route
        ;;
    disable)
        disable_side_route
        ;;
    *)
        echo "Usage: $0 {status|detect|backup|restore|enable|disable}"
        echo ""
        echo "Commands:"
        echo "  status    Show current mode and status"
        echo "  detect    Detect current network environment"
        echo "  backup    Backup current configuration"
        echo "  restore   Restore from backup"
        echo "  enable    Switch to side route mode"
        echo "  disable   Switch back to normal router mode"
        exit 1
        ;;
esac
