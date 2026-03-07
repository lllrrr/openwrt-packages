#!/bin/sh
# Easy MWAN3 Configuration Apply Script
# Converts easy_mwan3 config to mwan3 config
# Version: 2.1.1

. /lib/functions.sh
. /lib/functions/service.sh

LOG_TAG="easy_mwan3_apply"
MWAN3_CONFIG="/etc/config/mwan3"
EASY_CONFIG="/etc/config/easy_mwan3"

# 日志函数
log_msg() {
    logger -t "$LOG_TAG" "$1"
}

# 错误处理
error_exit() {
    log_msg "ERROR: $1"
    exit 1
}

# 检查 mwan3 是否安装
check_mwan3() {
    if [ ! -f /etc/init.d/mwan3 ]; then
        error_exit "mwan3 is not installed"
    fi
    
    if [ ! -f "$MWAN3_CONFIG" ]; then
        error_exit "mwan3 config file not found"
    fi
}

# 备份现有配置
backup_config() {
    if [ -f "$MWAN3_CONFIG" ]; then
        cp "$MWAN3_CONFIG" "${MWAN3_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        log_msg "Backup created: ${MWAN3_CONFIG}.backup.*"
    fi
}

# 清空 easy_mwan3 相关配置
clear_easy_config() {
    # 删除所有带有 easy_ 前缀的配置节
    uci -q batch <<EOF
delete mwan3.easy_balancing
delete mwan3.easy_failover
delete mwan3.easy_policy_wan
delete mwan3.easy_policy_wan2
delete mwan3.easy_rule_default
commit mwan3
EOF
    log_msg "Cleared existing easy_mwan3 configurations"
}

# 创建接口配置
create_interface_config() {
    local enabled
    config_get_bool enabled global enabled 0
    
    if [ "$enabled" != "1" ]; then
        log_msg "Easy MWAN3 is disabled, skipping configuration"
        return 0
    fi
    
    local mode
    config_get mode global mode "balance"
    
    local members
    config_get members global members
    
    if [ -z "$members" ]; then
        error_exit "No interfaces selected"
    fi
    
    log_msg "Creating interface configurations for mode: $mode"
    
    # 为每个接口创建 mwan3 配置
    for iface in $members; do
        # 检查接口是否存在
        if ! ubus call network.interface.$iface status >/dev/null 2>&1; then
            log_msg "Warning: Interface $iface not found, skipping"
            continue
        fi
        
        # 创建接口配置
        uci -q set "mwan3.${iface}=interface"
        uci -q set "mwan3.${iface}.enabled=1"
        uci -q set "mwan3.${iface}.track_ip=8.8.8.8"
        uci -q set "mwan3.${iface}.track_ip=8.8.4.4"
        uci -q set "mwan3.${iface}.reliability=1"
        uci -q set "mwan3.${iface}.count=1"
        uci -q set "mwan3.${iface}.timeout=2"
        uci -q set "mwan3.${iface}.interval=5"
        uci -q set "mwan3.${iface}.down=3"
        uci -q set "mwan3.${iface}.up=3"
        
        log_msg "Created interface config for: $iface"
    done
}

# 创建成员配置
create_member_config() {
    local members
    config_get members global members
    
    local member_list=""
    local metric=1
    
    for iface in $members; do
        # 创建成员
        uci -q set "mwan3.member_${iface}=member"
        uci -q set "mwan3.member_${iface}.interface=$iface"
        uci -q set "mwan3.member_${iface}.metric=$metric"
        uci -q set "mwan3.member_${iface}.weight=1"
        
        member_list="$member_list member_${iface}"
        metric=$((metric + 1))
        
        log_msg "Created member config for: $iface (metric=$metric)"
    done
    
    echo "$member_list"
}

# 创建策略配置
create_policy_config() {
    local mode
    config_get mode global mode "balance"
    
    local members
    config_get members global members
    
    local member_list=$(create_member_config)
    
    case "$mode" in
        balance)
            # 负载均衡策略
            uci -q set "mwan3.easy_balancing=policy"
            uci -q set "mwan3.easy_balancing.use_all=1"
            
            for member in $member_list; do
                uci -q add_list "mwan3.easy_balancing.use_member=$member"
            done
            
            log_msg "Created balanced policy"
            ;;
        failover)
            # 主备策略
            uci -q set "mwan3.easy_failover=policy"
            uci -q set "mwan3.easy_failover.use_all=0"
            
            for member in $member_list; do
                uci -q add_list "mwan3.easy_failover.use_member=$member"
            done
            
            log_msg "Created failover policy"
            ;;
        *)
            error_exit "Unknown mode: $mode"
            ;;
    esac
}

# 创建规则配置（设备策略）
create_rule_config() {
    local mode
    config_get mode global mode "balance"
    
    # 处理自定义规则
    local rule_num=0
    config_foreach create_single_rule rule
    
    # 创建默认规则
    local default_policy
    case "$mode" in
        balance)
            default_policy="easy_balancing"
            ;;
        failover)
            default_policy="easy_failover"
            ;;
    esac
    
    uci -q set "mwan3.easy_rule_default=rule"
    uci -q set "mwan3.easy_rule_default.use_policy=$default_policy"
    uci -q set "mwan3.easy_rule_default.proto=all"
    uci -q set "mwan3.easy_rule_default.priority=$((10000 + rule_num))"
    
    log_msg "Created default rule with policy: $default_policy"
}

# 创建单个规则
create_single_rule() {
    local rule_name=$1
    
    local src_ip
    config_get src_ip "$rule_name" src_ip
    
    local policy
    config_get policy "$rule_name" policy "default"
    
    local comment
    config_get comment "$rule_name" comment
    
    # 跳过默认策略
    [ "$policy" = "default" ] && return 0
    
    # 创建规则
    uci -q set "mwan3.easy_rule_${rule_name}=rule"
    
    if [ -n "$src_ip" ]; then
        uci -q set "mwan3.easy_rule_${rule_name}.src_ip=$src_ip"
    fi
    
    # 映射策略
    local mwan3_policy
    case "$policy" in
        wan_only)
            # 获取第一个接口
            local first_iface=$(echo $members | awk '{print $1}')
            mwan3_policy="member_${first_iface}"
            ;;
        wan2_only)
            # 获取第二个接口
            local second_iface=$(echo $members | awk '{print $2}')
            mwan3_policy="member_${second_iface}"
            ;;
        *)
            mwan3_policy="$policy"
            ;;
    esac
    
    uci -q set "mwan3.easy_rule_${rule_name}.use_policy=$mwan3_policy"
    uci -q set "mwan3.easy_rule_${rule_name}.proto=all"
    
    if [ -n "$comment" ]; then
        uci -q set "mwan3.easy_rule_${rule_name}.comment=$comment"
    fi
    
    rule_num=$((rule_num + 1))
    uci -q set "mwan3.easy_rule_${rule_name}.priority=$((1000 + rule_num))"
    
    log_msg "Created rule for: $src_ip -> $mwan3_policy"
}

# 应用配置
apply_config() {
    uci commit mwan3
    log_msg "Configuration committed"
    
    # 重启 mwan3 服务
    /etc/init.d/mwan3 restart 2>/dev/null || {
        error_exit "Failed to restart mwan3"
    }
    
    log_msg "MWAN3 service restarted successfully"
}

# 主函数
main() {
    log_msg "Starting configuration apply..."
    
    check_mwan3
    backup_config
    
    config_load easy_mwan3
    
    local enabled
    config_get_bool enabled global enabled 0
    
    if [ "$enabled" != "1" ]; then
        log_msg "Easy MWAN3 is disabled, clearing configuration"
        clear_easy_config
        /etc/init.d/mwan3 restart 2>/dev/null
        exit 0
    fi
    
    clear_easy_config
    create_interface_config
    create_policy_config
    create_rule_config
    apply_config
    
    log_msg "Configuration applied successfully"
}

main "$@"
