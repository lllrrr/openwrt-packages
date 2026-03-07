#!/bin/sh
# Easy MWAN3 Status Checker
# Version: 2.1.1

. /lib/functions.sh

# 获取接口状态
get_interface_status() {
    local iface=$1
    local status="offline"
    local uptime="-"
    local load="-"
    
    # 检查接口是否存在
    if ! ubus call network.interface.$iface status >/dev/null 2>&1; then
        echo "$iface|not_found|-|-"
        return
    fi
    
    # 获取接口状态
    local iface_status=$(ubus call network.interface.$iface status 2>/dev/null)
    
    if echo "$iface_status" | grep -q '"up":true'; then
        status="online"
        
        # 获取在线时间
        local uptime_sec=$(echo "$iface_status" | jsonfilter -e '@.uptime')
        if [ -n "$uptime_sec" ]; then
            local uptime_min=$((uptime_sec / 60))
            local uptime_hour=$((uptime_min / 60))
            uptime_min=$((uptime_min % 60))
            uptime="${uptime_hour}h ${uptime_min}m"
        fi
        
        # 获取网关
        local gateway=$(echo "$iface_status" | jsonfilter -e '@.route[0].target')
        if [ -n "$gateway" ]; then
            # Ping 网关测试延迟
            local latency=$(ping -c 1 -W 1 $gateway 2>/dev/null | grep 'time=' | sed 's/.*time=\(.*\) ms/\1/')
            if [ -n "$latency" ]; then
                load="${latency}ms"
            fi
        fi
    else
        status="offline"
    fi
    
    echo "$iface|$status|$uptime|$load"
}

# 检查 mwan3 服务状态
check_mwan3_service() {
    if /etc/init.d/mwan3 running >/dev/null 2>&1; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 获取所有接口状态（JSON格式）
get_all_interfaces_json() {
    local first=1
    echo "["
    
    config_load mwan3
    
    config_foreach process_interface_json interface
    
    echo "]"
}

process_interface_json() {
    local iface=$1
    
    [ $first -eq 0 ] && echo ","
    first=0
    
    local data=$(get_interface_status $iface)
    local name=$(echo $data | cut -d'|' -f1)
    local status=$(echo $data | cut -d'|' -f2)
    local uptime=$(echo $data | cut -d'|' -f3)
    local load=$(echo $data | cut -d'|' -f4)
    
    echo "  {"
    echo "    \"iface\": \"$name\","
    echo "    \"status\": \"$status\","
    echo "    \"uptime\": \"$uptime\","
    echo "    \"load\": \"$load\""
    echo "  }"
}

# 主函数
main() {
    case "$1" in
        json)
            get_all_interfaces_json
            ;;
        service)
            check_mwan3_service
            ;;
        interface)
            get_interface_status "$2"
            ;;
        *)
            echo "Usage: $0 {json|service|interface <name>}"
            exit 1
            ;;
    esac
}

main "$@"
