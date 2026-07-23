#!/bin/sh
# Home Assistant 管理后端脚本
# 支持 HA 容器状态查看、启停、日志查看、配置备份等

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

BACKUP_DIR="/etc/systools/backup/homeassistant"
HA_CONFIG_DIR="/root/homeassistant/config"
HA_CONTAINER_NAME="homeassistant"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 获取 HA 容器状态
get_ha_status() {
    check_docker || return 1
    
    local container_id
    local status
    local image
    local created
    local cpu_usage
    local mem_usage
    local version
    
    # 查找 HA 容器（支持多个可能的名字）
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        echo "status=not_found"
        echo "container_id="
        echo "image="
        echo "created="
        echo "cpu_usage="
        echo "mem_usage="
        echo "version="
        echo "running=no"
        return 0
    fi
    
    status=$(docker inspect -f "{{.State.Status}}" "$container_id" 2>/dev/null)
    image=$(docker inspect -f "{{.Config.Image}}" "$container_id" 2>/dev/null)
    created=$(docker inspect -f "{{.Created}}" "$container_id" 2>/dev/null)
    
    # 获取资源使用情况
    local stats
    stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$container_id" 2>/dev/null)
    cpu_usage=$(echo "$stats" | cut -d'|' -f1)
    mem_usage=$(echo "$stats" | cut -d'|' -f2)
    
    # 获取版本号
    version=$(docker exec "$container_id" python -m homeassistant --version 2>/dev/null | head -1)
    
    echo "status=$status"
    echo "container_id=$container_id"
    echo "image=$image"
    echo "created=$created"
    echo "cpu_usage=$cpu_usage"
    echo "mem_usage=$mem_usage"
    echo "version=$version"
    if [ "$status" = "running" ]; then
        echo "running=yes"
    else
        echo "running=no"
    fi
}

# 启动 HA
start_ha() {
    check_docker || return 1
    
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        log_error "Home Assistant container not found"
        return 1
    fi
    
    docker start "$container_id" 2>/dev/null
    echo "Home Assistant started"
    return 0
}

# 停止 HA
stop_ha() {
    check_docker || return 1
    
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        log_error "Home Assistant container not found"
        return 1
    fi
    
    docker stop "$container_id" 2>/dev/null
    echo "Home Assistant stopped"
    return 0
}

# 重启 HA
restart_ha() {
    check_docker || return 1
    
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        log_error "Home Assistant container not found"
        return 1
    fi
    
    docker restart "$container_id" 2>/dev/null
    echo "Home Assistant restarted"
    return 0
}

# 查看 HA 日志
get_ha_logs() {
    check_docker || return 1
    
    local lines="${1:-100}"
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        log_error "Home Assistant container not found"
        return 1
    fi
    
    docker logs --tail "$lines" "$container_id" 2>&1
    return 0
}

# 备份 HA 配置
backup_ha_config() {
    check_docker || return 1
    
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    if [ -z "$container_id" ]; then
        log_error "Home Assistant container not found"
        return 1
    fi
    
    # 查找配置目录
    local config_path
    config_path=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$container_id" 2>/dev/null)
    
    if [ -z "$config_path" ]; then
        # 尝试常见路径
        config_path="$HA_CONFIG_DIR"
    fi
    
    if [ ! -d "$config_path" ]; then
        log_error "HA config directory not found: $config_path"
        return 1
    fi
    
    local backup_file
    backup_file="$BACKUP_DIR/ha_config_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    tar -czf "$backup_file" -C "$(dirname "$config_path")" "$(basename "$config_path")" 2>/dev/null
    
    if [ -f "$backup_file" ]; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        echo "Backup created: $backup_file"
        echo "Size: $size"
        return 0
    else
        log_error "Backup failed"
        return 1
    fi
}

# 列出备份文件
list_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "No backups found"
        return 0
    fi
    
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | sort -r | while read -r line; do
        local size date time filename
        size=$(echo "$line" | awk '{print $5}')
        date=$(echo "$line" | awk '{print $6}')
        time=$(echo "$line" | awk '{print $7}')
        filename=$(echo "$line" | awk '{print $9}')
        echo "filename|$size|$date $time"
    done
}

# 获取存储占用统计
get_storage_stats() {
    check_docker || return 1
    
    local container_id
    container_id=$(docker ps -a --format "{{.ID}} {{.Names}}" 2>/dev/null | grep -E "homeassistant|home-assistant" | head -1 | awk '{print $1}')
    
    local config_size="0"
    local db_size="0"
    local backup_size="0"
    local free_space="0"
    
    # 配置目录大小
    if [ -n "$container_id" ]; then
        local config_path
        config_path=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$container_id" 2>/dev/null)
        if [ -d "$config_path" ]; then
            config_size=$(du -sh "$config_path" 2>/dev/null | cut -f1)
            if [ -f "$config_path/home-assistant_v2.db" ]; then
                db_size=$(du -h "$config_path/home-assistant_v2.db" 2>/dev/null | cut -f1)
            fi
        fi
    fi
    
    # 备份大小
    if [ -d "$BACKUP_DIR" ]; then
        backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    fi
    
    # 剩余空间
    free_space=$(df -h "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    
    echo "config_size=$config_size"
    echo "db_size=$db_size"
    echo "backup_size=$backup_size"
    echo "free_space=$free_space"
}

# 主入口
case "$1" in
    status)
        get_ha_status
        ;;
    start)
        start_ha
        ;;
    stop)
        stop_ha
        ;;
    restart)
        restart_ha
        ;;
    logs)
        get_ha_logs "$2"
        ;;
    backup)
        backup_ha_config
        ;;
    list_backups)
        list_backups
        ;;
    storage)
        get_storage_stats
        ;;
    *)
        echo "Usage: $0 {status|start|stop|restart|logs [lines]|backup|list_backups|storage}"
        exit 1
        ;;
esac
