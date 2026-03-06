#!/bin/bash
# SocksClash v1.2.0 内核管理脚本
# 参考 OpenClash 实现，支持版本检测、自动更新、重试机制

START_LOG="/tmp/socks-clash_start.log"
LOG_FILE="/tmp/socks-clash.log"
CORE_DIR="/etc/socks-clash/core"
CORE_PATH="$CORE_DIR/clash"
TMP_DIR="/tmp/socks-clash"

# 日志函数
LOG_OUT() {
    if [ -n "${1}" ]; then
        echo -e "${1}" > "$START_LOG"
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") ${1}" >> "$LOG_FILE"
    fi
}

SLOG_CLEAN() {
    echo "##FINISH##" > "$START_LOG"
}

# 锁机制
set_lock() {
    exec 872>"/tmp/lock/socks_clash_core.lock" 2>/dev/null
    flock -x 872 2>/dev/null
}

del_lock() {
    flock -u 872 2>/dev/null
    rm -rf "/tmp/lock/socks_clash_core.lock" 2>/dev/null
}

trap 'del_lock' EXIT

# 获取系统架构
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armhf)
            echo "armv7"
            ;;
        i686|i386)
            echo "386"
            ;;
        mips)
            echo "mips-softfloat"
            ;;
        mipsel)
            echo "mipsle-softfloat"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 获取最新版本号
get_latest_version() {
    local api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    local version=$(curl -sL --connect-timeout 10 "$api_url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -n "$version" ]; then
        echo "$version"
        return 0
    else
        # 回退到固定版本
        echo "v1.18.10"
        return 1
    fi
}

# 获取当前版本
get_current_version() {
    if [ -x "$CORE_PATH" ]; then
        "$CORE_PATH" -v 2>/dev/null | head -1 | awk '{print $3}'
    else
        echo ""
    fi
}

# 下载内核
download_core() {
    local arch="$1"
    local version="$2"
    local force="$3"
    
    if [ "$arch" = "unknown" ]; then
        LOG_OUT "Error: 不支持的系统架构: $(uname -m)"
        return 1
    fi
    
    LOG_OUT "========================================="
    LOG_OUT "Tip: 开始下载 Clash Meta 内核"
    LOG_OUT "Tip: 系统架构: $arch"
    LOG_OUT "Tip: 目标版本: $version"
    LOG_OUT "========================================="
    
    mkdir -p "$CORE_DIR"
    mkdir -p "$TMP_DIR"
    mkdir -p "/tmp/lock"
    
    local filename="mihomo-linux-$arch-$version.gz"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/$version/$filename"
    local download_file="$TMP_DIR/$filename"
    local tmp_core="$TMP_DIR/clash_tmp"
    
    # 重试机制
    local retry_count=0
    local max_retries=3
    local download_success=false
    
    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))
        
        LOG_OUT "Tip:【$retry_count/$max_retries】正在下载内核..."
        LOG_OUT "Tip: 下载地址: $download_url"
        
        rm -f "$download_file" "$tmp_core"
        
        if curl -sL --connect-timeout 30 --max-time 600 \
            -o "$download_file" "$download_url" 2>&1; then
            
            if [ -s "$download_file" ]; then
                LOG_OUT "Tip: 下载成功，正在验证文件..."
                
                # 验证 gzip 文件
                if gzip -t "$download_file" >/dev/null 2>&1; then
                    LOG_OUT "Tip: 文件验证成功，正在解压..."
                    
                    if gunzip -c "$download_file" > "$tmp_core" 2>&1; then
                        chmod 755 "$tmp_core"
                        
                        # 验证内核可执行
                        if "$tmp_core" -v >/dev/null 2>&1; then
                            download_success=true
                            break
                        else
                            LOG_OUT "Error:【$retry_count/$max_retries】内核验证失败"
                        fi
                    else
                        LOG_OUT "Error:【$retry_count/$max_retries】解压失败"
                    fi
                else
                    LOG_OUT "Error:【$retry_count/$max_retries】文件损坏，重新下载..."
                fi
            else
                LOG_OUT "Error:【$retry_count/$max_retries】下载的文件为空"
            fi
        else
            LOG_OUT "Error:【$retry_count/$max_retries】下载失败"
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            sleep 2
        fi
    done
    
    if [ "$download_success" = "true" ]; then
        LOG_OUT "Tip: 正在安装内核..."
        
        # 如果服务正在运行，先停止
        if pgrep -f "$CORE_PATH" >/dev/null 2>&1; then
            LOG_OUT "Tip: 停止正在运行的服务..."
            /etc/init.d/socks-clash stop >/dev/null 2>&1
            sleep 1
        fi
        
        # 备份旧内核
        if [ -f "$CORE_PATH" ]; then
            cp "$CORE_PATH" "${CORE_PATH}.bak"
        fi
        
        # 安装新内核
        if mv "$tmp_core" "$CORE_PATH"; then
            local installed_version=$("$CORE_PATH" -v 2>/dev/null | head -1)
            LOG_OUT "Tip: ========================================="
            LOG_OUT "Tip: Clash Meta 内核安装成功!"
            LOG_OUT "Tip: 已安装版本: $installed_version"
            LOG_OUT "Tip: 内核路径: $CORE_PATH"
            LOG_OUT "Tip: ========================================="
            
            rm -f "$download_file" "${CORE_PATH}.bak"
            
            # 如果之前服务在运行，重启服务
            if [ "$(uci -q get socks-clash.config.enable)" = "1" ]; then
                LOG_OUT "Tip: 正在重启服务..."
                /etc/init.d/socks-clash restart >/dev/null 2>&1
            fi
            
            return 0
        else
            LOG_OUT "Error: 内核安装失败"
            # 恢复备份
            if [ -f "${CORE_PATH}.bak" ]; then
                mv "${CORE_PATH}.bak" "$CORE_PATH"
                LOG_OUT "Tip: 已恢复旧版本内核"
            fi
            return 1
        fi
    else
        LOG_OUT "Error: 内核下载失败，已重试 $max_retries 次"
        LOG_OUT "Tip: 请检查网络连接或稍后重试"
        LOG_OUT "Tip: 如果无法访问 GitHub，可以手动下载内核并上传"
        rm -f "$download_file" "$tmp_core"
        return 1
    fi
}

# 检查更新
check_update() {
    LOG_OUT "Tip: 正在检查内核更新..."
    
    local current_version=$(get_current_version)
    local latest_version=$(get_latest_version)
    
    if [ -z "$current_version" ]; then
        LOG_OUT "Tip: 未检测到内核"
        return 2
    fi
    
    LOG_OUT "Tip: 当前版本: $current_version"
    LOG_OUT "Tip: 最新版本: $latest_version"
    
    # 简单的版本比较
    if [ "$current_version" != "$latest_version" ]; then
        LOG_OUT "Tip: 发现新版本"
        return 0
    else
        LOG_OUT "Tip: 已是最新版本"
        return 1
    fi
}

# 主程序
set_lock

ACTION="$1"
FORCE="$2"

LOG_OUT "========================================="
LOG_OUT "Tip: SocksClash 内核管理 v1.2.0"
LOG_OUT "========================================="

ARCH=$(get_arch)

case "$ACTION" in
    install)
        LOG_OUT "Tip: 执行内核安装..."
        LATEST_VERSION=$(get_latest_version)
        download_core "$ARCH" "$LATEST_VERSION" "$FORCE"
        ;;
    update)
        LOG_OUT "Tip: 执行内核更新..."
        if check_update; then
            LATEST_VERSION=$(get_latest_version)
            download_core "$ARCH" "$LATEST_VERSION" "force"
        else
            LOG_OUT "Tip: 无需更新"
        fi
        ;;
    check)
        check_update
        ;;
    force)
        LOG_OUT "Tip: 强制重新安装内核..."
        LATEST_VERSION=$(get_latest_version)
        download_core "$ARCH" "$LATEST_VERSION" "force"
        ;;
    *)
        # 默认行为：如果没有内核则安装，有则检查更新
        CURRENT_VERSION=$(get_current_version)
        if [ -z "$CURRENT_VERSION" ]; then
            LOG_OUT "Tip: 未检测到内核，开始安装..."
            LATEST_VERSION=$(get_latest_version)
            download_core "$ARCH" "$LATEST_VERSION"
        else
            LOG_OUT "Tip: 检测到已安装内核: $CURRENT_VERSION"
            if [ "$FORCE" = "force" ]; then
                LOG_OUT "Tip: 强制更新模式..."
                LATEST_VERSION=$(get_latest_version)
                download_core "$ARCH" "$LATEST_VERSION" "force"
            else
                LOG_OUT "Tip: 如需更新，请使用 'update' 或 'force' 参数"
            fi
        fi
        ;;
esac

LOG_OUT "========================================="
LOG_OUT "Tip: 操作完成"
LOG_OUT "========================================="
SLOG_CLEAN

del_lock
