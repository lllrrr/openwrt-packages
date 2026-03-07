#!/bin/sh
# Easy MWAN3 Hybrid Policy Engine
# Version: 2.1.1
# Implements hybrid strategy with both global load balancing and device-specific policies

. /lib/functions.sh

LOG_TAG="easy_mwan3_policy"

log_msg() {
    logger -t "$LOG_TAG" "$1"
}

# 混合策略引擎
# 支持同时使用：
# 1. 全局负载均衡
# 2. 特定设备强制走特定线路
# 3. 基于应用的策略（未来扩展）

create_hybrid_policy() {
    local members
    config_get members global members
    
    local mode
    config_get mode global mode "balance"
    
    log_msg "Creating hybrid policy for mode: $mode"
    
    # 1. 创建负载均衡策略（全局默认）
    case "$mode" in
        balance)
            create_balance_policy "$members"
            ;;
        failover)
            create_failover_policy "$members"
            ;;
    esac
    
    # 2. 创建设备特定策略
    create_device_policies "$members"
    
    # 3. 创建策略规则（按优先级）
    create_policy_rules "$members"
}

# 创建负载均衡策略
create_balance_policy() {
    local members=$1
    
    uci -q set "mwan3.policy_balance=policy"
    uci -q set "mwan3.policy_balance.use_all=1"
    uci -q set "mwan3.policy_balance.last_resort=default"
    
    for iface in $members; do
        # 创建成员
        uci -q set "mwan3.member_${iface}=member"
        uci -q set "mwan3.member_${iface}.interface=$iface"
        uci -q set "mwan3.member_${iface}.metric=1"
        uci -q set "mwan3.member_${iface}.weight=1"
        
        # 添加到策略
        uci -q add_list "mwan3.policy_balance.use_member=member_${iface}"
    done
    
    log_msg "Created balanced policy with members: $members"
}

# 创建主备策略
create_failover_policy() {
    local members=$1
    local first=1
    local primary_iface=""
    
    uci -q set "mwan3.policy_failover=policy"
    uci -q set "mwan3.policy_failover.use_all=0"
    uci -q set "mwan3.policy_failover.last_resort=default"
    
    for iface in $members; do
        local metric=1
        
        if [ $first -eq 1 ]; then
            # 主接口
            metric=1
            primary_iface=$iface
            first=0
        else
            # 备用接口（metric 越大优先级越低）
            metric=$((metric + 2))
        fi
        
        # 创建成员
        uci -q set "mwan3.member_${iface}=member"
        uci -q set "mwan3.member_${iface}.interface=$iface"
        uci -q set "mwan3.member_${iface}.metric=$metric"
        uci -q set "mwan3.member_${iface}.weight=1"
        
        # 添加到策略
        uci -q add_list "mwan3.policy_failover.use_member=member_${iface}"
    done
    
    log_msg "Created failover policy. Primary: $primary_iface"
}

# 创建设备特定策略
create_device_policies() {
    local members=$1
    local rule_num=100
    
    config_foreach create_device_rule rule "$members" rule_num
}

# 创建单个设备规则
create_device_rule() {
    local rule_name=$1
    local members=$2
    local rule_num_ref=$3
    
    local src_ip
    config_get src_ip "$rule_name" src_ip
    
    local policy
    config_get policy "$rule_name" policy "default"
    
    local comment
    config_get comment "$rule_name" comment
    
    # 跳过默认策略
    [ "$policy" = "default" ] && return 0
    
    [ -z "$src_ip" ] && return 0
    
    # 创建策略
    local policy_name="policy_device_${rule_name}"
    uci -q set "mwan3.${policy_name}=policy"
    uci -q set "mwan3.${policy_name}.use_all=0"
    uci -q set "mwan3.${policy_name}.last_resort=default"
    
    # 根据策略类型添加成员
    case "$policy" in
        wan_only)
            local first_iface=$(echo $members | awk '{print $1}')
            uci -q add_list "mwan3.${policy_name}.use_member=member_${first_iface}"
            ;;
        wan2_only)
            local second_iface=$(echo $members | awk '{print $2}')
            uci -q add_list "mwan3.${policy_name}.use_member=member_${second_iface}"
            ;;
        *)
            # 自定义策略
            ;;
    esac
    
    # 创建规则
    local rule_name_mwan3="rule_device_${rule_name}"
    uci -q set "mwan3.${rule_name_mwan3}=rule"
    uci -q set "mwan3.${rule_name_mwan3}.src_ip=$src_ip"
    uci -q set "mwan3.${rule_name_mwan3}.use_policy=${policy_name}"
    uci -q set "mwan3.${rule_name_mwan3}.proto=all"
    uci -q set "mwan3.${rule_name_mwan3}.sticky=0"
    uci -q set "mwan3.${rule_name_mwan3}.priority=$((rule_num_ref))"
    
    if [ -n "$comment" ]; then
        uci -q set "mwan3.${rule_name_mwan3}.comment=$comment"
    fi
    
    log_msg "Created device policy: $src_ip -> $policy"
    
    # 更新规则编号
    eval "$rule_num_ref=\$((rule_num_ref + 1))"
}

# 创建策略规则（按优先级）
create_policy_rules() {
    local members=$1
    
    # 默认规则（优先级最低）
    local default_policy
    config_get mode global mode "balance"
    
    case "$mode" in
        balance)
            default_policy="policy_balance"
            ;;
        failover)
            default_policy="policy_failover"
            ;;
    esac
    
    # 创建默认规则
    uci -q set "mwan3.rule_default=rule"
    uci -q set "mwan3.rule_default.use_policy=$default_policy"
    uci -q set "mwan3.rule_default.proto=all"
    uci -q set "mwan3.rule_default.priority=10000"
    
    log_msg "Created default rule with policy: $default_policy"
}

# 主函数
main() {
    case "$1" in
        create)
            config_load easy_mwan3
            create_hybrid_policy
            ;;
        *)
            echo "Usage: $0 {create}"
            exit 1
            ;;
    esac
}

main "$@"
