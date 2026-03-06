#!/bin/bash
# SocksClash v1.2.0 GeoIP/GeoSite 更新脚本

START_LOG="/tmp/socks-clash_start.log"
LOG_FILE="/tmp/socks-clash.log"
RULE_DIR="/etc/socks-clash/rule"

LOG_OUT() {
    if [ -n "${1}" ]; then
        echo -e "${1}" > "$START_LOG"
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") ${1}" >> "$LOG_FILE"
    fi
}

SLOG_CLEAN() {
    echo "##FINISH##" > "$START_LOG"
}

set_lock() {
    exec 873>"/tmp/lock/socks_clash_geo.lock" 2>/dev/null
    flock -x 873 2>/dev/null
}

del_lock() {
    flock -u 873 2>/dev/null
    rm -rf "/tmp/lock/socks_clash_geo.lock" 2>/dev/null
}

trap 'del_lock' EXIT

update_geoip() {
    LOG_OUT "Tip: 正在更新 GeoIP 数据库..."
    
    local geoip_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    local tmp_file="/tmp/geoip.dat.tmp"
    local target_file="$RULE_DIR/geoip.dat"
    
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))
        
        LOG_OUT "Tip:【$retry_count/$max_retries】下载 GeoIP..."
        
        if curl -sL --connect-timeout 30 --max-time 300 \
            -o "$tmp_file" "$geoip_url" 2>&1; then
            
            if [ -s "$tmp_file" ]; then
                mv "$tmp_file" "$target_file"
                LOG_OUT "Tip: GeoIP 更新成功"
                return 0
            fi
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            sleep 2
        fi
    done
    
    LOG_OUT "Error: GeoIP 更新失败"
    rm -f "$tmp_file"
    return 1
}

update_geosite() {
    LOG_OUT "Tip: 正在更新 GeoSite 数据库..."
    
    local geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    local tmp_file="/tmp/geosite.dat.tmp"
    local target_file="$RULE_DIR/geosite.dat"
    
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))
        
        LOG_OUT "Tip:【$retry_count/$max_retries】下载 GeoSite..."
        
        if curl -sL --connect-timeout 30 --max-time 300 \
            -o "$tmp_file" "$geosite_url" 2>&1; then
            
            if [ -s "$tmp_file" ]; then
                mv "$tmp_file" "$target_file"
                LOG_OUT "Tip: GeoSite 更新成功"
                return 0
            fi
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            sleep 2
        fi
    done
    
    LOG_OUT "Error: GeoSite 更新失败"
    rm -f "$tmp_file"
    return 1
}

# 主程序
set_lock
mkdir -p "$RULE_DIR"
mkdir -p "/tmp/lock"

LOG_OUT "========================================="
LOG_OUT "Tip: 开始更新 GeoIP/GeoSite 数据库"
LOG_OUT "========================================="

update_geoip
update_geosite

# 如果服务正在运行，重新加载配置
if pgrep -f "/etc/socks-clash/core/clash" >/dev/null 2>&1; then
    LOG_OUT "Tip: 正在重新加载配置..."
    /etc/init.d/socks-clash restart >/dev/null 2>&1
fi

LOG_OUT "========================================="
LOG_OUT "Tip: 更新完成"
LOG_OUT "========================================="
SLOG_CLEAN

del_lock
