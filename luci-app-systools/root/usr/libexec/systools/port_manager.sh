#!/bin/sh
# 网口管理后端脚本
# 支持网口WAN/LAN分配、配置备份、恢复默认、倒计时确认

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

BACKUP_DIR="/etc/systools/backup/port_manager"
BACKUP_FILE="$BACKUP_DIR/network_$(date +%Y%m%d_%H%M%S).tar.gz"
LATEST_BACKUP="$BACKUP_DIR/network_latest.tar.gz"
ROLLBACK_MARKER="/var/run/systools_port_manager_rollback"
CONFIRM_MARKER="/var/run/systools_port_manager_confirmed"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 备份网络配置
backup_config() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # 备份 network 配置
    uci export network > "$tmpdir/network.uci" 2>/dev/null

    # 打包
    tar -czf "$BACKUP_FILE" -C "$tmpdir" . 2>/dev/null
    cp "$BACKUP_FILE" "$LATEST_BACKUP"

    rm -rf "$tmpdir"

    if [ -f "$BACKUP_FILE" ]; then
        log_info "Backup saved: $BACKUP_FILE"
        return 0
    else
        log_error "Backup failed"
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
        log_error "No backup found"
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)

    tar -xzf "$backup_file" -C "$tmpdir" 2>/dev/null

    # 恢复配置
    if [ -f "$tmpdir/network.uci" ]; then
        uci import network < "$tmpdir/network.uci" 2>/dev/null
    fi

    uci commit network

    rm -rf "$tmpdir"

    log_info "Restored from: $backup_file"
    return 0
}

# 获取所有物理网口列表
get_physical_ports() {
    local ports=""
    # 遍历/sys/class/net下的接口，排除虚拟接口
    for iface in /sys/class/net/*; do
        local name
        name=$(basename "$iface")
        # 排除lo、br-、veth、docker、wg、tun、tap等虚拟接口
        case "$name" in
            lo|br-*|veth*|docker*|wg*|tun*|tap*|imq*|ifb*|teql*|gre*|ip6tnl*|sit*|ipip*|ppp*|eth0.*|*.1q|*.1ad)
                continue
                ;;
        esac
        # 检查是否是物理接口（有device链接或phy端口）
        if [ -e "$iface/device" ] || [ -d "/sys/class/net/$name/phyport" ] || echo "$name" | grep -qE "^(eth|lan|wan|port)[0-9]*$"; then
            ports="$ports $name"
        fi
    done
    echo "$ports" | tr ' ' '\n' | sort | tr '\n' ' '
}

# 获取LAN口列表（br-lan的ports）
get_lan_ports() {
    local ports=""
    # 遍历所有device section，找到name='br-lan'的那个
    local dev_idx=0
    while [ $dev_idx -lt 10 ]; do
        local dev_name
        dev_name=$(uci get network.@device[$dev_idx].name 2>/dev/null)
        if [ "$dev_name" = "br-lan" ]; then
            local br_ports
            br_ports=$(uci get network.@device[$dev_idx].ports 2>/dev/null)
            if [ -n "$br_ports" ]; then
                ports="$br_ports"
            fi
            break
        fi
        dev_idx=$((dev_idx + 1))
    done

    # 如果没找到config device，尝试旧语法：直接在interface lan中设置ifname
    if [ -z "$ports" ]; then
        local ifname
        ifname=$(uci get network.lan.ifname 2>/dev/null)
        if [ -n "$ifname" ]; then
            ports="$ifname"
        fi
    fi
    echo "$ports"
}

# 获取WAN口
get_wan_port() {
    uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null
}

# 获取当前状态（供CBI页面读取）
get_status() {
    echo "===PORT_MANAGER_STATUS==="
    local all_ports
    all_ports=$(get_physical_ports)
    local lan_ports
    lan_ports=$(get_lan_ports)
    local wan_port
    wan_port=$(get_wan_port)

    echo "all_ports=$all_ports"
    echo "lan_ports=$lan_ports"
    echo "wan_port=$wan_port"

    # 逐个输出每个网口的角色
    for port in $all_ports; do
        local role="unused"
        # 检查是否是WAN口
        if [ "$port" = "$wan_port" ]; then
            role="wan"
        fi
        # 检查是否在LAN列表中
        for lp in $lan_ports; do
            if [ "$port" = "$lp" ]; then
                role="lan"
                break
            fi
        done
        # 获取网口速度信息
        local speed="unknown"
        if [ -f "/sys/class/net/$port/speed" ]; then
            speed=$(cat "/sys/class/net/$port/speed" 2>/dev/null)
        fi
        # 获取链路状态
        local carrier="down"
        if [ -f "/sys/class/net/$port/carrier" ]; then
            if [ "$(cat /sys/class/net/$port/carrier 2>/dev/null)" = "1" ]; then
                carrier="up"
            fi
        fi
        echo "port_${port}_role=$role"
        echo "port_${port}_speed=$speed"
        echo "port_${port}_carrier=$carrier"
    done

    # 检查是否有待确认的配置（倒计时中）
    if [ -f "$ROLLBACK_MARKER" ]; then
        echo "pending_rollback=yes"
        local rollback_time
        rollback_time=$(cat "$ROLLBACK_MARKER" 2>/dev/null)
        echo "rollback_time=$rollback_time"
    else
        echo "pending_rollback=no"
    fi

    echo "===END_STATUS==="
}

# 应用网口配置
# 参数：lan_ports="lan2 lan3" wan_port="eth1"
apply_config() {
    local lan_ports="$1"
    local wan_port="$2"

    if [ -z "$lan_ports" ] || [ -z "$wan_port" ]; then
        log_error "Missing parameters: lan_ports and wan_port are required"
        return 1
    fi

    # 验证：至少1个LAN口
    local lan_count
    lan_count=$(echo "$lan_ports" | wc -w)
    if [ "$lan_count" -lt 1 ]; then
        log_error "At least one LAN port is required"
        return 1
    fi

    # 验证：WAN口不能与LAN口重复
    for lp in $lan_ports; do
        if [ "$lp" = "$wan_port" ]; then
            log_error "WAN port cannot be the same as LAN port"
            return 1
        fi
    done

    # 备份当前配置
    backup_config

    # 应用新配置
    log_info "Applying port configuration: LAN=$lan_ports WAN=$wan_port"

    # 1. 更新LAN bridge的ports列表
    # 先检查是否有config device类型的br-lan
    local has_device=0
    uci show network 2>/dev/null | grep -q "network\.@device\[" && has_device=1

    if [ "$has_device" = "1" ]; then
        # 新语法：更新config device的ports
        # 找到br-lan对应的device section
        local dev_idx=0
        local found=0
        while [ $dev_idx -lt 10 ]; do
            local dev_name
            dev_name=$(uci get network.@device[$dev_idx].name 2>/dev/null)
            if [ "$dev_name" = "br-lan" ]; then
                # 删除旧的ports列表
                uci delete network.@device[$dev_idx].ports 2>/dev/null
                # 添加新的ports
                for lp in $lan_ports; do
                    uci add_list network.@device[$dev_idx].ports="$lp"
                done
                found=1
                break
            fi
            dev_idx=$((dev_idx + 1))
        done
        # 如果没找到br-lan的device section，创建一个
        if [ "$found" = "0" ]; then
            uci set network.@device[0]=device 2>/dev/null || uci add network device
            uci set network.@device[0].name='br-lan'
            uci set network.@device[0].type='bridge'
            for lp in $lan_ports; do
                uci add_list network.@device[0].ports="$lp"
            done
        fi
        # 确保interface lan引用br-lan
        uci set network.lan.device='br-lan'
        uci delete network.lan.ifname 2>/dev/null
    else
        # 旧语法：直接设置interface lan的ifname
        uci set network.lan.ifname="$lan_ports"
        uci delete network.lan.device 2>/dev/null
    fi

    # 2. 更新WAN口
    uci set network.wan.device="$wan_port"
    uci delete network.wan.ifname 2>/dev/null

    # 3. 更新WAN6口（如果存在）
    if uci get network.wan6 >/dev/null 2>&1; then
        uci set network.wan6.device="$wan_port"
        uci delete network.wan6.ifname 2>/dev/null
    fi

    # 提交配置
    uci commit network

    log_info "Configuration applied, restarting network..."

    # 设置回滚标记（30秒后自动回滚）
    echo "$(date -d '+30 seconds' +%s 2>/dev/null || echo $(( $(date +%s) + 30 )))" > "$ROLLBACK_MARKER"
    rm -f "$CONFIRM_MARKER"

    # 后台启动回滚倒计时
    (
        sleep 30
        if [ ! -f "$CONFIRM_MARKER" ] && [ -f "$ROLLBACK_MARKER" ]; then
            log_warn "Rollback timeout, restoring previous configuration..."
            restore_config
            /etc/init.d/network restart >/dev/null 2>&1
        fi
        rm -f "$ROLLBACK_MARKER"
    ) &

    # 重启网络
    /etc/init.d/network restart >/dev/null 2>&1

    log_info "Network restarted, configuration applied successfully"
    return 0
}

# 确认配置（取消倒计时回滚）
confirm_config() {
    touch "$CONFIRM_MARKER"
    rm -f "$ROLLBACK_MARKER"
    log_info "Configuration confirmed, rollback cancelled"
    return 0
}

# 立即回滚
rollback_config() {
    restore_config
    /etc/init.d/network restart >/dev/null 2>&1
    rm -f "$ROLLBACK_MARKER" "$CONFIRM_MARKER"
    log_info "Configuration rolled back"
    return 0
}

# 恢复默认配置（lan2 lan3 lan4=LAN, eth1=WAN）
restore_default() {
    # 检测设备类型，设置默认配置
    local board
    board=$(cat /tmp/sysinfo/board_name 2>/dev/null)

    local default_lan="lan1 lan2 lan3 lan4"
    local default_wan="eth1"

    # 针对XG-040G-MD设备
    if echo "$board" | grep -q "xg-040g-md"; then
        default_lan="lan2 lan3 lan4"
        default_wan="eth1"
    fi

    log_info "Restoring default configuration: LAN=$default_lan WAN=$default_wan"
    apply_config "$default_lan" "$default_wan"
    return $?
}

# 主函数
case "$1" in
    status)
        get_status
        ;;
    apply)
        apply_config "$2" "$3"
        ;;
    restore)
        restore_config "$2"
        ;;
    default)
        restore_default
        ;;
    confirm)
        confirm_config
        ;;
    rollback)
        rollback_config
        ;;
    *)
        echo "Usage: $0 {status|apply <lan_ports> <wan_port>|restore [backup_file]|default|confirm|rollback}"
        exit 1
        ;;
esac
