#!/bin/sh
# 智能家居网络设置脚本
# 管理常用端口、mDNS、UPnP 等

# 常用智能家居端口
COMMON_PORTS="8123:Home Assistant:tcp 1883:MQTT:tcp 8883:MQTT SSL:tcp 8080:Zigbee2MQTT:tcp 1880:Node-RED:tcp 6052:ESPHome:tcp"

# 检查端口是否开放（通过防火墙规则）
check_port_open() {
    local port="$1"
    local proto="${2:-tcp}"
    
    # 检查防火墙规则
    if iptables -C input_rule -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
        echo "open"
        return 0
    fi
    
    # 也检查 nftables
    if command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q "dport $proto.*$port.*accept"; then
            echo "open"
            return 0
        fi
    fi
    
    echo "closed"
    return 1
}

# 开放端口
open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local name="${3:-port-$port}"
    
    echo "Opening port $port/$proto ($name)"
    
    # 使用 uci 添加防火墙规则
    local rule_name="smarthome_${name}_${port}_${proto}"
    
    # 遍历所有规则检查是否已存在
    local idx=0
    local found=0
    while uci get "firewall.@rule[$idx].name" >/dev/null 2>&1; do
        local existing_name
        existing_name=$(uci get "firewall.@rule[$idx].name" 2>/dev/null)
        if [ "$existing_name" = "$rule_name" ]; then
            found=1
            break
        fi
        idx=$((idx + 1))
    done
    
    if [ "$found" -eq 1 ]; then
        echo "Port already open"
        return 0
    fi
    
    # 添加规则
    uci add firewall rule >/dev/null 2>&1
    uci set firewall.@rule[-1].name="$rule_name"
    uci set firewall.@rule[-1].src="wan"
    uci set firewall.@rule[-1].proto="$proto"
    uci set firewall.@rule[-1].dest_port="$port"
    uci set firewall.@rule[-1].target="ACCEPT"
    uci commit firewall
    
    # 重启防火墙
    /etc/init.d/firewall reload 2>/dev/null
    
    echo "Port $port opened"
    return 0
}

# 关闭端口
close_port() {
    local port="$1"
    local proto="${2:-tcp}"
    
    echo "Closing port $port/$proto"
    
    # 循环删除所有匹配的规则（每次删完重新遍历，避免索引偏移问题）
    local deleted=0
    local keep_going=1
    
    while [ "$keep_going" -eq 1 ]; do
        keep_going=0
        local total=$(uci show firewall 2>/dev/null | grep -c "^firewall.@rule\[")
        
        # 从最后一个规则往前遍历
        for ((count = total - 1; count >= 0; count--)); do
            local rule_name
            rule_name=$(uci get "firewall.@rule[$count].name" 2>/dev/null)
            
            # 只处理 smarthome_ 开头的规则
            if echo "$rule_name" | grep -q "^smarthome_"; then
                local rule_port
                rule_port=$(uci get "firewall.@rule[$count].dest_port" 2>/dev/null)
                local rule_proto
                rule_proto=$(uci get "firewall.@rule[$count].proto" 2>/dev/null)
                
                if [ "$rule_port" = "$port" ] && [ "$rule_proto" = "$proto" ]; then
                    uci delete "firewall.@rule[$count]"
                    uci commit firewall
                    deleted=$((deleted + 1))
                    keep_going=1  # 删除了一个，继续找下一个
                    break  # 索引变了，重新从后往前找
                fi
            fi
        done
    done
    
    if [ "$deleted" -gt 0 ]; then
        /etc/init.d/firewall reload 2>/dev/null
        echo "Port $port closed ($deleted rules removed)"
        return 0
    else
        echo "Port rule not found"
        return 1
    fi
}

# 列出所有端口状态
list_ports() {
    for entry in $COMMON_PORTS; do
        local port name proto
        port=$(echo "$entry" | cut -d: -f1)
        name=$(echo "$entry" | cut -d: -f2)
        proto=$(echo "$entry" | cut -d: -f3)
        
        local status
        status=$(check_port_open "$port" "$proto")
        
        echo "$port|$name|$proto|$status"
    done
}

# 检查 mDNS 服务状态
check_mdns() {
    # 检查 avahi 或 umdns
    if command -v avahi-daemon >/dev/null 2>&1; then
        if /etc/init.d/avahi-daemon running 2>/dev/null; then
            echo "running"
            echo "service=avahi-daemon"
            return 0
        fi
    fi
    
    if command -v umdns >/dev/null 2>&1; then
        if pgrep -x umdns >/dev/null 2>&1; then
            echo "running"
            echo "service=umdns"
            return 0
        fi
    fi
    
    echo "stopped"
    echo "service=none"
    return 1
}

# 启用 mDNS
enable_mdns() {
    echo "Enabling mDNS..."
    
    # 尝试启用 umdns（OpenWrt 自带的轻量 mDNS）
    if command -v umdns >/dev/null 2>&1; then
        /etc/init.d/umdns enable 2>/dev/null
        /etc/init.d/umdns start 2>/dev/null
        echo "mDNS enabled (umdns)"
        return 0
    fi
    
    # 尝试启用 avahi
    if command -v avahi-daemon >/dev/null 2>&1; then
        /etc/init.d/avahi-daemon enable 2>/dev/null
        /etc/init.d/avahi-daemon start 2>/dev/null
        echo "mDNS enabled (avahi-daemon)"
        return 0
    fi
    
    echo "ERROR: No mDNS service found"
    return 1
}

# 禁用 mDNS
disable_mdns() {
    echo "Disabling mDNS..."
    
    if /etc/init.d/umdns running 2>/dev/null; then
        /etc/init.d/umdns stop 2>/dev/null
        /etc/init.d/umdns disable 2>/dev/null
        echo "mDNS disabled (umdns)"
        return 0
    fi
    
    if /etc/init.d/avahi-daemon running 2>/dev/null; then
        /etc/init.d/avahi-daemon stop 2>/dev/null
        /etc/init.d/avahi-daemon disable 2>/dev/null
        echo "mDNS disabled (avahi-daemon)"
        return 0
    fi
    
    echo "mDNS already stopped"
    return 0
}

# 检查 UPnP 状态
check_upnp() {
    if command -v miniupnpd >/dev/null 2>&1; then
        if /etc/init.d/miniupnpd running 2>/dev/null; then
            echo "running"
            echo "service=miniupnpd"
            return 0
        fi
    fi
    
    echo "stopped"
    echo "service=none"
    return 1
}

# 启用 UPnP
enable_upnp() {
    echo "Enabling UPnP..."
    
    if command -v miniupnpd >/dev/null 2>&1; then
        /etc/init.d/miniupnpd enable 2>/dev/null
        /etc/init.d/miniupnpd start 2>/dev/null
        echo "UPnP enabled"
        return 0
    fi
    
    echo "ERROR: miniupnpd not found"
    return 1
}

# 禁用 UPnP
disable_upnp() {
    echo "Disabling UPnP..."
    
    if /etc/init.d/miniupnpd running 2>/dev/null; then
        /etc/init.d/miniupnpd stop 2>/dev/null
        /etc/init.d/miniupnpd disable 2>/dev/null
        echo "UPnP disabled"
        return 0
    fi
    
    echo "UPnP already stopped"
    return 0
}

# 主入口
case "$1" in
    ports_list)
        list_ports
        ;;
    port_open)
        open_port "$2" "$3" "$4"
        ;;
    port_close)
        close_port "$2" "$3"
        ;;
    mdns_status)
        check_mdns
        ;;
    mdns_enable)
        enable_mdns
        ;;
    mdns_disable)
        disable_mdns
        ;;
    upnp_status)
        check_upnp
        ;;
    upnp_enable)
        enable_upnp
        ;;
    upnp_disable)
        disable_upnp
        ;;
    *)
        echo "Usage: $0 {ports_list|port_open <port> [proto] [name]|port_close <port> [proto]|mdns_status|mdns_enable|mdns_disable|upnp_status|upnp_enable|upnp_disable}"
        exit 1
        ;;
esac
