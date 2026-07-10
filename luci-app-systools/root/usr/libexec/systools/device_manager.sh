#!/bin/sh
# 设备管理脚本
# 功能：设备列表、备注名管理、静态IP绑定

BACKUP_DIR="/etc/systools/backup"
LOG_TAG="systools-device-manager"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$1"
}

backup_config() {
    log "备份配置..."
    mkdir -p "$BACKUP_DIR"
    
    # 备份 DHCP 配置
    cp /etc/config/dhcp "$BACKUP_DIR/dhcp.backup" 2>/dev/null
    
    # 备份 systools 配置
    cp /etc/config/systools "$BACKUP_DIR/systools.backup" 2>/dev/null
    
    log "配置备份完成"
}

rollback_config() {
    log "回滚配置..."
    
    if [ -f "$BACKUP_DIR/dhcp.backup" ]; then
        cp "$BACKUP_DIR/dhcp.backup" /etc/config/dhcp
        /etc/init.d/dnsmasq restart 2>/dev/null
        log "DHCP 配置已回滚"
    fi
    
    if [ -f "$BACKUP_DIR/systools.backup" ]; then
        cp "$BACKUP_DIR/systools.backup" /etc/config/systools
        log "systools 配置已回滚"
    fi
    
    log "配置回滚完成"
}

get_device_list() {
    # 从 ARP 表获取设备
    cat /proc/net/arp | grep -v "IP address" | while read line; do
        ip=$(echo "$line" | awk '{print $1}')
        mac=$(echo "$line" | awk '{print $4}')
        iface=$(echo "$line" | awk '{print $6}')
        
        # 跳过无效条目
        if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
            continue
        fi
        
        # 获取主机名
        hostname=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}' | head -1)
        if [ -z "$hostname" ]; then
            hostname="未知设备"
        fi
        
        # 检查是否有备注名（统一小写，避免大小写不一致）
        mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
        mac_safe=$(echo "$mac_lower" | tr ':' '_')
        nickname=$(uci get systools.device_$mac_safe.nickname 2>/dev/null)
        if [ -n "$nickname" ]; then
            display_name="$nickname"
        else
            display_name="$hostname"
        fi
        
        # 检查是否静态绑定（通过 MAC 地址匹配，更准确）
        static="否"
        local check_idx=0
        while uci get "dhcp.@host[$check_idx].mac" >/dev/null 2>&1; do
            local entry_mac
            entry_mac=$(uci get "dhcp.@host[$check_idx].mac" 2>/dev/null)
            entry_mac_lower=$(echo "$entry_mac" | tr '[:upper:]' '[:lower:]')
            if [ "$entry_mac_lower" = "$mac_lower" ]; then
                static="是"
                break
            fi
            check_idx=$((check_idx + 1))
        done
        
        echo "$ip|$mac|$display_name|$iface|$static"
    done
}

set_nickname() {
    local mac="$1"
    local nickname="$2"
    
    if [ -z "$mac" ] || [ -z "$nickname" ]; then
        log "错误：MAC 地址和备注名不能为空"
        return 1
    fi
    
    # 统一转小写，避免大小写不一致
    local mac_lower
    mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    local mac_safe=$(echo "$mac_lower" | tr ':' '_')
    
    # 设置备注名
    uci set systools.device_$mac_safe=systools
    uci set systools.device_$mac_safe.nickname="$nickname"
    uci set systools.device_$mac_safe.mac="$mac_lower"
    uci commit systools
    
    log "设备 $mac 备注名已设置为: $nickname"
    return 0
}

set_static_ip() {
    local mac="$1"
    local ip="$2"
    local enable="$3"
    
    if [ -z "$mac" ] || [ -z "$ip" ]; then
        log "错误：MAC 地址和 IP 地址不能为空"
        return 1
    fi
    
    # 检查 IP 格式
    if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        log "错误：IP 地址格式不正确"
        return 1
    fi
    
    # 检查 MAC 格式
    if ! echo "$mac" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        log "错误：MAC 地址格式不正确"
        return 1
    fi
    
    # 统一转小写，避免大小写不一致
    local mac_lower
    mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    
    # 查找该 MAC 已有的 host 条目索引
    local idx=0
    local found=0
    while uci get "dhcp.@host[$idx].mac" >/dev/null 2>&1; do
        local entry_mac
        entry_mac=$(uci get "dhcp.@host[$idx].mac" 2>/dev/null)
        # 统一转小写比较
        entry_mac_lower=$(echo "$entry_mac" | tr '[:upper:]' '[:lower:]')
        if [ "$entry_mac_lower" = "$mac_lower" ]; then
            found=1
            break
        fi
        idx=$((idx + 1))
    done
    
    if [ "$enable" = "1" ] || [ "$enable" = "true" ]; then
        # 添加或更新静态绑定
        if [ "$found" -eq 1 ]; then
            # 更新已有条目
            uci set "dhcp.@host[$idx].ip=$ip"
            uci set "dhcp.@host[$idx].leasetime=infinite"
            log "设备 $mac_lower 静态绑定已更新: $ip"
        else
            # 添加新条目
            uci add dhcp host >/dev/null
            uci set "dhcp.@host[-1].name=static_$(echo "$mac_lower" | tr ':' '_')"
            uci set "dhcp.@host[-1].mac=$mac_lower"
            uci set "dhcp.@host[-1].ip=$ip"
            uci set "dhcp.@host[-1].leasetime=infinite"
            log "设备 $mac_lower 已绑定静态 IP: $ip"
        fi
        uci commit dhcp
        
        # 重启 dnsmasq
        /etc/init.d/dnsmasq restart 2>/dev/null
    else
        # 移除静态绑定
        if [ "$found" -eq 1 ]; then
            uci delete "dhcp.@host[$idx]"
            uci commit dhcp
            /etc/init.d/dnsmasq restart 2>/dev/null
            log "设备 $mac_lower 静态绑定已移除"
        else
            log "设备 $mac_lower 没有找到静态绑定条目"
        fi
    fi
    
    return 0
}

apply_config() {
    log "应用设备管理配置..."
    
    # 备份当前配置
    backup_config
    
    # 从 systools 配置读取并应用
    # 备注名已经在 uci 里了，不需要额外处理
    
    # 静态 IP 绑定已经在 set_static_ip 函数里处理了
    
    log "设备管理配置应用完成"
}

case "$1" in
    list)
        get_device_list
        ;;
    set-nickname)
        set_nickname "$2" "$3"
        ;;
    set-static)
        set_static_ip "$2" "$3" "$4"
        ;;
    apply)
        apply_config
        ;;
    rollback)
        rollback_config
        ;;
    *)
        echo "用法: $0 {list|set-nickname|set-static|apply|rollback}"
        echo "  list                    - 列出所有设备"
        echo "  set-nickname <mac> <name> - 设置设备备注名"
        echo "  set-static <mac> <ip> <enable> - 设置静态IP绑定"
        echo "  apply                   - 应用配置"
        echo "  rollback                - 回滚配置"
        exit 1
        ;;
esac
