#!/bin/bash
# SocksClash v1.2.0 批量节点测速脚本

START_LOG="/tmp/socks-clash_start.log"
LOG_FILE="/tmp/socks-clash.log"
UCI_CONFIG="socks-clash"

LOG_OUT() {
    if [ -n "${1}" ]; then
        echo -e "${1}" > "$START_LOG"
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") ${1}" >> "$LOG_FILE"
    fi
}

SLOG_CLEAN() {
    echo "##FINISH##" > "$START_LOG"
}

. /lib/functions.sh

LOG_OUT "========================================="
LOG_OUT "Tip: 开始批量测速"
LOG_OUT "========================================="

total=0
tested=0

test_server() {
    local section="$1"
    local enabled=$(uci -q get "$UCI_CONFIG.$section.enabled")
    
    if [ "$enabled" = "1" ]; then
        total=$((total + 1))
        local alias=$(uci -q get "$UCI_CONFIG.$section.alias")
        
        LOG_OUT "Tip: 测试节点 [$total]: $alias"
        
        if sh /usr/share/socks-clash/test_proxy.sh "$section"; then
            local delay=$(cat "/tmp/socks-clash_delay_$section" 2>/dev/null || echo "0")
            if [ "$delay" != "0" ]; then
                LOG_OUT "Tip: 延迟: ${delay}ms"
                tested=$((tested + 1))
            else
                LOG_OUT "Tip: 超时"
            fi
        else
            LOG_OUT "Error: 测试失败"
        fi
        
        # 避免同时发起太多请求
        sleep 0.5
    fi
}

config_load "$UCI_CONFIG"
config_foreach test_server servers

LOG_OUT "========================================="
LOG_OUT "Tip: 测速完成: 成功 $tested / 共 $total"
LOG_OUT "========================================="
SLOG_CLEAN
