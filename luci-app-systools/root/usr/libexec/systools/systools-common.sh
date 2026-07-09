#!/bin/sh
# System Tools - Common Functions Library
# 系统工具 - 公共函数库
# 所有脚本共享的通用函数

# 日志函数
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# 获取 OpenWrt 版本
get_openwrt_version() {
    local version
    version=$(cat /etc/openwrt_version 2>/dev/null)
    if [ -z "$version" ]; then
        version=$(cat /etc/os-release 2>/dev/null | grep '^VERSION_ID=' | cut -d'"' -f2)
    fi
    echo "$version"
}

# 获取包管理器类型
get_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    else
        echo "unknown"
    fi
}

# 获取系统架构
get_architecture() {
    local arch
    arch=$(uname -m)
    echo "$arch"
}

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# 查找 Docker 容器（支持多个名称模式）
# 参数：一个或多个容器名称模式（模糊匹配）
# 返回：找到的第一个容器 ID
find_container() {
    if ! check_docker; then
        return 1
    fi
    
    local container_id=""
    
    # 遍历所有参数（名称模式）
    for pattern in "$@"; do
        container_id=$(docker ps -a --filter "name=^/${pattern}$" --format "{{.ID}}" 2>/dev/null | head -1)
        if [ -n "$container_id" ]; then
            echo "$container_id"
            return 0
        fi
    done
    
    # 如果精确匹配没找到，尝试模糊匹配
    for pattern in "$@"; do
        container_id=$(docker ps -a --filter "name=${pattern}" --format "{{.ID}}" 2>/dev/null | head -1)
        if [ -n "$container_id" ]; then
            echo "$container_id"
            return 0
        fi
    done
    
    return 1
}

# 备份文件
backup_file() {
    local file="$1"
    local backup_suffix="${2:-.bak.$(date +%Y%m%d_%H%M%S)}"
    
    if [ -f "$file" ]; then
        cp -a "$file" "${file}${backup_suffix}"
        return 0
    fi
    return 1
}

# 安全地修改 JSON 配置中的字段
# 参数：文件路径、字段名、新值
set_json_field() {
    local file="$1"
    local field="$2"
    local value="$3"
    
    # 确保目录存在
    mkdir -p "$(dirname "$file")"
    
    if [ -f "$file" ]; then
        # 文件存在，检查字段是否已存在
        if grep -q "\"${field}\"" "$file" 2>/dev/null; then
            # 字段存在，替换值
            sed -i "s|\"${field}\": *\"[^\"]*\"|\"${field}\": \"${value}\"|" "$file" 2>/dev/null
        else
            # 字段不存在，添加到第一个 { 后面
            sed -i "s|{|{\n  \"${field}\": \"${value}\",|" "$file" 2>/dev/null
        fi
    else
        # 文件不存在，创建新的
        cat > "$file" <<EOF
{
  "${field}": "${value}"
}
EOF
    fi
}

# 重启 Docker 服务
restart_docker() {
    log_info "正在重启 Docker 服务..."
    
    if command -v /etc/init.d/dockerd >/dev/null 2>&1; then
        /etc/init.d/dockerd restart >/dev/null 2>&1
    elif command -v /etc/init.d/docker >/dev/null 2>&1; then
        /etc/init.d/docker restart >/dev/null 2>&1
    else
        # 尝试直接重启 dockerd 进程
        killall dockerd 2>/dev/null
        sleep 2
        dockerd >/dev/null 2>&1 &
    fi
    
    # 等待 Docker 启动
    local wait_count=0
    while ! docker info >/dev/null 2>&1; do
        sleep 2
        wait_count=$((wait_count + 1))
        if [ $wait_count -gt 30 ]; then
            log_warn "Docker 启动超时"
            return 1
        fi
    done
    
    log_info "Docker 服务已重启"
    return 0
}

# 停止 Docker 服务
stop_docker() {
    log_info "正在停止 Docker 服务..."
    
    if command -v /etc/init.d/dockerd >/dev/null 2>&1; then
        /etc/init.d/dockerd stop >/dev/null 2>&1
    elif command -v /etc/init.d/docker >/dev/null 2>&1; then
        /etc/init.d/docker stop >/dev/null 2>&1
    else
        killall dockerd 2>/dev/null
    fi
    
    sleep 3
    log_info "Docker 已停止"
}

# 复制目录（包括隐藏文件）
copy_dir_contents() {
    local src="$1"
    local dst="$2"
    
    if [ ! -d "$src" ]; then
        return 1
    fi
    
    mkdir -p "$dst"
    
    # 使用 find 复制所有文件，包括隐藏文件
    (cd "$src" && find . -maxdepth 1 -exec cp -a {} "$dst/" \;) 2>/dev/null
    
    return 0
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 验证 IP 地址格式
is_valid_ip() {
    local ip="$1"
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [ $? -ne 0 ]; then
        return 1
    fi
    # 检查每个字节是否在 0-255 范围内
    echo "$ip" | awk -F. '{if ($1<=255 && $2<=255 && $3<=255 && $4<=255) exit 0; else exit 1}'
}

# 验证端口号
is_valid_port() {
    local port="$1"
    echo "$port" | grep -qE '^[0-9]+$' || return 1
    if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# 验证 MAC 地址格式
is_valid_mac() {
    local mac="$1"
    echo "$mac" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}
