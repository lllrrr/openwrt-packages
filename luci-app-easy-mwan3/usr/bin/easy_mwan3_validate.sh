#!/bin/sh
# Easy MWAN3 Configuration Validator
# Version: 2.1.1

. /lib/functions.sh

LOG_TAG="easy_mwan3_validate"

log_msg() {
    logger -t "$LOG_TAG" "$1"
}

# 验证 IP 地址
validate_ip() {
    local ip=$1
    local regex="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
    
    if echo "$ip" | grep -qE "$regex"; then
        # 验证每个八位字节
        local IFS='.'
        set -- $ip
        [ $1 -le 255 ] && [ $2 -le 255 ] && [ $3 -le 255 ] && [ $4 -le 255 ]
        return $?
    fi
    return 1
}

# 验证接口是否存在
validate_interface() {
    local iface=$1
    
    # 检查网络接口
    if ubus call network.interface.$iface status >/dev/null 2>&1; then
        return 0
    fi
    
    # 检查物理设备
    if [ -d "/sys/class/net/$iface" ]; then
        return 0
    fi
    
    return 1
}

# 验证配置
validate_config() {
    local errors=0
    local warnings=0
    
    config_load easy_mwan3
    
    # 检查是否启用
    local enabled
    config_get_bool enabled global enabled 0
    
    if [ "$enabled" != "1" ]; then
        echo "INFO: Easy MWAN3 is disabled"
        return 0
    fi
    
    # 检查模式
    local mode
    config_get mode global mode "balance"
    
    if [ "$mode" != "balance" ] && [ "$mode" != "failover" ]; then
        echo "ERROR: Invalid mode: $mode (must be 'balance' or 'failover')"
        errors=$((errors + 1))
    fi
    
    # 检查成员接口
    local members
    config_get members global members
    
    if [ -z "$members" ]; then
        echo "ERROR: No interfaces selected"
        errors=$((errors + 1))
    else
        local iface_count=0
        for iface in $members; do
            if ! validate_interface "$iface"; then
                echo "ERROR: Interface '$iface' does not exist"
                errors=$((errors + 1))
            else
                # 检查接口是否在线
                if ! ubus call network.interface.$iface status 2>/dev/null | grep -q '"up":true'; then
                    echo "WARNING: Interface '$iface' is not online"
                    warnings=$((warnings + 1))
                fi
                iface_count=$((iface_count + 1))
            fi
        done
        
        # 检查接口数量
        if [ "$mode" = "failover" ] && [ $iface_count -lt 2 ]; then
            echo "ERROR: Failover mode requires at least 2 interfaces"
            errors=$((errors + 1))
        fi
        
        if [ $iface_count -lt 1 ]; then
            echo "ERROR: At least 1 interface required"
            errors=$((errors + 1))
        fi
    fi
    
    # 检查自定义规则
    config_foreach validate_rule rule
    
    # 总结
    echo ""
    echo "Validation completed:"
    echo "  Errors: $errors"
    echo "  Warnings: $warnings"
    
    if [ $errors -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# 验证单个规则
validate_rule() {
    local rule_name=$1
    
    local src_ip
    config_get src_ip "$rule_name" src_ip
    
    local policy
    config_get policy "$rule_name" policy "default"
    
    # 验证 IP 地址
    if [ -n "$src_ip" ]; then
        if ! validate_ip "$src_ip"; then
            echo "ERROR: Invalid IP address in rule '$rule_name': $src_ip"
            errors=$((errors + 1))
        fi
    fi
    
    # 验证策略
    case "$policy" in
        default|wan_only|wan2_only)
            # 有效策略
            ;;
        *)
            echo "ERROR: Invalid policy in rule '$rule_name': $policy"
            errors=$((errors + 1))
            ;;
    esac
}

# 主函数
main() {
    case "$1" in
        config)
            validate_config
            return $?
            ;;
        interface)
            validate_interface "$2"
            return $?
            ;;
        ip)
            validate_ip "$2"
            return $?
            ;;
        *)
            echo "Usage: $0 {config|interface <name>|ip <address>}"
            exit 1
            ;;
    esac
}

main "$@"
