#!/bin/sh
# Docker 存储管理后端脚本

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

# 异常中断清理函数
cleanup() {
    # 清理临时文件
    rm -f /tmp/systools_storage_*.log 2>/dev/null
    rm -f /tmp/systools_migrate_*.tmp 2>/dev/null
    # 注意：锁文件保留，由陈旧锁检测机制处理
}

# 设置信号捕获
trap cleanup EXIT INT TERM


# 获取当前 Docker 数据目录
get_data_root() {
    check_docker || return 1
    local data_root
    data_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
    if [ -z "$data_root" ]; then
        data_root="/opt/docker"
    fi
    echo "$data_root"
}

# 备份当前配置
backup_config() {
    local backup_dir="/etc/systools/backup/docker_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    # 备份 daemon.json
    if [ -f "/etc/docker/daemon.json" ]; then
        cp /etc/docker/daemon.json "$backup_dir/daemon.json"
    fi
    echo "$backup_dir"
}

# 回滚配置
rollback_config() {
    local backup_dir="$1"
    echo "正在回滚配置..."
    # 恢复 daemon.json
    if [ -f "$backup_dir/daemon.json" ]; then
        cp "$backup_dir/daemon.json" /etc/docker/daemon.json
    else
        rm -f /etc/docker/daemon.json
    fi
    # ===== 步骤5：重启 Docker =====
    # 重启 Docker
    restart_docker
    echo "配置已回滚"
}

# 重启 Docker 服务
restart_docker() {
    echo "正在重启 Docker 服务..."
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
            echo "WARNING: Docker 启动超时"
            return 1
        fi
    done
    echo "Docker 服务已重启"
    return 0
}

# 迁移 Docker 数据目录
migrate_data_root() {
    # 获取操作锁，防止并发迁移
    if ! acquire_lock "docker_migrate"; then
        log_error "数据迁移正在进行中，请稍后再试"
        return 1
    fi
    log_audit "docker_migrate_start" "$target_path=$1"
    local new_path="$1"
    if ! check_docker; then
        release_lock "docker_migrate"
        return 1
    fi

    if [ -z "$new_path" ]; then
        log_error "请指定目标路径"
        release_lock "docker_migrate"
        return 1
    fi

    log_info "========================================"
    echo "Docker 数据目录迁移"
    log_info "========================================"

    # 获取当前数据目录
    local old_path
    old_path=$(get_data_root)
    echo "当前数据目录: $old_path"
    echo "目标数据目录: $new_path"
    echo ""

    # ===== 步骤1：参数校验 =====
    # 检查目标路径是否存在
    if [ ! -d "$new_path" ]; then
        log_error "目标路径不存在: $new_path"
        echo "请先挂载 U 盘并创建目录"
        release_lock "docker_migrate"
        return 1
    fi

    # 检查目标路径是否可写
    if ! touch "$new_path/.test_write" 2>/dev/null; then
        log_error "目标路径不可写: $new_path"
        release_lock "docker_migrate"
        return 1
    fi
    rm -f "$new_path/.test_write"

    # 备份当前配置
    echo "备份当前配置..."
    local backup_dir
    backup_dir=$(backup_config)
    echo "备份目录: $backup_dir"
    echo ""

    # 停止 Docker
    echo "停止 Docker 服务..."
    if command -v /etc/init.d/dockerd >/dev/null 2>&1; then
        /etc/init.d/dockerd stop >/dev/null 2>&1
    elif command -v /etc/init.d/docker >/dev/null 2>&1; then
        /etc/init.d/docker stop >/dev/null 2>&1
    else
        killall dockerd 2>/dev/null
    fi
    sleep 3
    echo "Docker 已停止"
    echo ""

    # 复制数据
    echo "复制数据到新位置..."
    echo "这可能需要一些时间，请耐心等待..."
    echo ""

    if [ -d "$old_path" ]; then
        # 使用 cp -a 复制所有数据，保留权限（包括隐藏文件）
        if cp -a "$old_path"/. "$new_path/" 2>/dev/null; then
            echo "数据复制完成"
        else
            log_error "数据复制失败"
            echo "正在回滚..."
            rollback_config "$backup_dir"
            return 1
        fi
    else
        echo "警告: 原数据目录不存在，跳过数据复制"
    fi

    echo ""

    # 修改 daemon.json 配置
    echo "修改 Docker 配置..."
    local daemon_json="/etc/docker/daemon.json"

    # 使用公共函数修改 data-root 字段（自动备份、优先 jq、sed 兜底）
    set_json_field "$daemon_json" "data-root" "$new_path"

    echo "配置已更新"
    echo ""

    # ===== 步骤5：重启 Docker =====
    # 重启 Docker
    if restart_docker; then
        echo ""
        log_info "========================================"
        log_info "迁移完成！"
        echo "新的数据目录: $new_path"
        log_info "========================================"

    # ===== 步骤6：验证结果 =====
        # 验证新的数据目录
        local new_data_root
        new_data_root=$(get_data_root)
        echo "验证: 当前数据目录 = $new_data_root"
        if [ "$new_data_root" = "$new_path" ]; then
            echo "验证通过 ✓"
        else
            echo "警告: 验证失败，数据目录可能未正确切换"
        fi

    # 释放锁
    release_lock "docker_migrate"
    log_audit "docker_migrate_success" "$target_path=$new_path"
        # 清理备份
        rm -rf "$backup_dir"
        return 0
    else
        echo ""
        log_error "Docker 重启失败"
        echo "正在回滚..."
        release_lock "docker_migrate"
        log_audit "docker_migrate_failed" "$target_path=$new_path"
        rollback_config "$backup_dir"
        return 1
    fi
}

# 获取存储状态
get_storage_status() {
    check_docker || return 1
    local data_root
    data_root=$(get_data_root)
    echo "data_root=$data_root"

    # 获取磁盘使用情况
    if [ -d "$data_root" ]; then
        local df_output
        df_output=$(df -h "$data_root" 2>/dev/null | tail -1)
        local total used avail use_pct
        total=$(echo "$df_output" | awk '{print $2}')
        used=$(echo "$df_output" | awk '{print $3}')
        avail=$(echo "$df_output" | awk '{print $4}')
        use_pct=$(echo "$df_output" | awk '{print $5}')
        echo "total=$total"
        echo "used=$used"
        echo "avail=$avail"
        echo "use_pct=$use_pct"

        # 低空间告警：剩余 < 10%
        local use_num
        use_num=$(echo "$use_pct" | tr -d '%')
        if [ "$use_num" -gt 90 ] 2>/dev/null; then
            echo "low_space_warning=yes"
        else
            echo "low_space_warning=no"
        fi
    fi
}

# 格式化U盘为ext4
format_disk() {
    local device="$1"
    # 获取并发锁
    if ! acquire_lock "disk_format"; then
        log_error "格式化操作正在进行中，请稍后再试"
        return 1
    fi
    if [ -z "$device" ]; then
        log_error "请指定设备路径"
        release_lock "disk_format"
        return 1
    fi

    # 检查设备是否存在
    if [ ! -b "$device" ]; then
        log_error "设备不存在: $device"
        release_lock "disk_format"
        return 1
    fi

    log_info "========================================"
    echo "格式化设备: $device"
    log_info "========================================"
    echo "警告：格式化将删除设备上所有数据！"
    echo ""

    # 检查设备是否已挂载，如果已挂载先卸载
    if mountpoint -q "$device" 2>/dev/null; then
        echo "设备已挂载，正在卸载..."
        umount "$device" 2>/dev/null || {
            log_error "卸载设备失败"
            release_lock "disk_format"
            return 1
        }
        echo "卸载完成"
    fi

    # 检查是否安装了mkfs.ext4
    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        log_error "缺少 mkfs.ext4 工具，请先安装 e2fsprogs"
        release_lock "disk_format"
        return 1
    fi

    echo "开始格式化为 ext4 文件系统..."
    echo "这可能需要几分钟，请耐心等待..."
    echo ""

    # 执行格式化
    if mkfs.ext4 -F "$device" >/dev/null 2>&1; then
        echo ""
        log_info "========================================"
        log_info "格式化完成！"
        log_info "========================================"
        release_lock "disk_format"
        return 0
    else
        echo ""
        log_error "格式化失败"
        release_lock "disk_format"
        return 1
    fi
}

# 空间占用分析
get_storage_analysis() {
    check_docker || return 1

    echo "=== 镜像占用空间排行 ==="
    if command -v docker >/dev/null 2>&1; then
        docker images --format "{{.Size}} {{.Repository}}:{{.Tag}}" 2>/dev/null | sort -hr | head -10
    fi

    echo ""
    echo "=== 容器占用空间排行 ==="
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format "{{.Size}} {{.Names}}" 2>/dev/null | sort -hr | head -10
    fi
}

# 列出已挂载的存储设备
list_mounts() {
    df -hT 2>/dev/null | grep -E 'ext4|ext3|vfat|ntfs' | grep -v '/rom' | grep -v '/overlay'
}

# 主入口
case "$1" in
    status)
        get_storage_status
        ;;
    migrate)
        migrate_data_root "$2"
        ;;
    mounts)
        list_mounts
        ;;
    format)
        format_disk "$2"
        ;;
    analysis)
        get_storage_analysis
        ;;
    *)
        echo "Usage: $0 {status|migrate <path>|mounts|format <device>|analysis}"
        exit 1
        ;;
esac
