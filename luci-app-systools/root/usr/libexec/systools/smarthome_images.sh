#!/bin/sh
# Docker 镜像管理后端脚本

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

# 异常中断清理函数
cleanup() {
    rm -f /tmp/systools_pull_*.log 2>/dev/null
}

trap cleanup EXIT INT TERM


# 获取镜像加速地址
get_mirror_url() {
    local mirror_source="$1"
    local custom_mirror="$2"

    case "$mirror_source" in
        aliyun)
            echo "https://registry.cn-hangzhou.aliyuncs.com"
            ;;
        netease)
            echo "https://hub-mirror.c.163.com"
            ;;
        ustc)
            echo "https://docker.mirrors.ustc.edu.cn"
            ;;
        custom)
            echo "$custom_mirror"
            ;;
        official|*)
            echo ""
            ;;
    esac
}

# 配置镜像加速
configure_mirror() {
    local mirror_source="$1"
    local custom_mirror="$2"

    if [ "$mirror_source" = "official" ] || [ -z "$mirror_source" ]; then
        return 0
    fi

    local mirror_url
    mirror_url=$(get_mirror_url "$mirror_source" "$custom_mirror")

    if [ -z "$mirror_url" ]; then
        return 0
    fi

    # 创建 daemon.json 配置
    local daemon_json="/etc/docker/daemon.json"

    if [ ! -d "/etc/docker" ]; then
        mkdir -p /etc/docker
    fi

    # 检查是否已有配置
    if [ -f "$daemon_json" ]; then
        # 检查是否已有 registry-mirrors
        if grep -q "registry-mirrors" "$daemon_json" 2>/dev/null; then
            # 更新现有配置（简单替换）
            sed -i "s|\"registry-mirrors\": \[\"[^\"]*\"\]|\"registry-mirrors\": [\"$mirror_url\"]|" "$daemon_json" 2>/dev/null
        else
            # 添加 registry-mirrors
            sed -i "s|{|{\n  \"registry-mirrors\": [\"$mirror_url\"],|" "$daemon_json" 2>/dev/null
        fi
    else
        # 创建新配置
        cat > "$daemon_json" <<EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
    fi

    # 重启 Docker 使配置生效
    if command -v /etc/init.d/dockerd >/dev/null 2>&1; then
        /etc/init.d/dockerd restart >/dev/null 2>&1 &
    fi
}

# 拉取镜像
pull_image() {
    # 获取操作锁，防止并发拉取
    if ! acquire_lock "docker_pull"; then
        log_error "镜像拉取正在进行中，请稍后再试"
        return 1
    fi
    log_audit "docker_pull_start" "image=$1"
    local image_name="$1"
    if [ -z "$image_name" ]; then
        log_error "镜像名称不能为空"
        release_lock "docker_pull"
        return 1
    fi
    local mirror_source="$2"
    local custom_mirror="$3"

    check_docker || return 1

    if [ -z "$image_name" ]; then
        log_error "Image name required"
        return 1
    fi

    log_info "========================================"
    echo "开始拉取镜像: $image_name"
    echo "镜像源: $mirror_source"
    log_info "========================================"

    # 配置镜像加速
    if [ "$mirror_source" != "official" ] && [ -n "$mirror_source" ]; then
        echo "配置镜像加速源..."
        configure_mirror "$mirror_source" "$custom_mirror"
        sleep 2
    fi

    # 拉取镜像
    echo "正在拉取镜像，请稍候..."
    echo ""

    if docker pull "$image_name" 2>&1; then
        echo ""
        log_info "========================================"
        release_lock "docker_pull"
        log_audit "docker_pull_success" "image=$image_name"
        log_info "镜像拉取成功: $image_name"
        log_info "========================================"
        return 0
    else
        echo ""
        log_info "========================================"
        release_lock "docker_pull"
        log_audit "docker_pull_failed" "image=$image_name"
        log_error "镜像拉取失败: $image_name"
        log_info "========================================"
        return 1
    fi
}

# 列出所有镜像
list_images() {
    check_docker || return 1

    docker images --format "{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}" 2>/dev/null
}

# 获取镜像详情
get_image_info() {
    local image_id="$1"

    check_docker || return 1

    if [ -z "$image_id" ]; then
        log_error "Image ID required"
        return 1
    fi

    local repo tag size created

    repo=$(docker inspect -f "{{.RepoTags}}" "$image_id" 2>/dev/null | sed 's/\[//;s/\]//')
    size=$(docker inspect -f "{{.Size}}" "$image_id" 2>/dev/null)
    created=$(docker inspect -f "{{.Created}}" "$image_id" 2>/dev/null)

    # 转换大小为人类可读
    if [ -n "$size" ]; then
        size=$(echo "$size" | awk '{printf "%.2f MB", $1/1024/1024}')
    fi

    echo "id=$image_id"
    echo "repo=$repo"
    echo "size=$size"
    echo "created=$created"
}

# 删除镜像
remove_image() {
    local image_id="$1"

    check_docker || return 1

    if [ -z "$image_id" ]; then
        log_error "Image ID required"
        return 1
    fi

    # 检查是否有容器在使用这个镜像
    local containers
    containers=$(docker ps -a --filter "ancestor=$image_id" --format "{{.ID}}" 2>/dev/null)

    if [ -n "$containers" ]; then
        log_error "Image is in use by containers, please remove containers first"
        return 1
    fi

    docker rmi "$image_id" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "Image removed: $image_id"
        return 0
    else
        log_error "Failed to remove image"
        return 1
    fi
}

# 清理无用镜像（悬空镜像）
prune_images() {
    check_docker || return 1

    local count
    count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)

    if [ "$count" -eq 0 ]; then
        echo "No dangling images to clean"
        return 0
    fi

    docker image prune -f 2>/dev/null
    echo "Cleaned $count dangling images"
    return 0
}

# 获取镜像统计
get_image_stats() {
    check_docker || return 1

    local total_count total_size

    total_count=$(docker images -q 2>/dev/null | wc -l)
    total_size=$(docker system df 2>/dev/null | grep "Images" | awk '{print $4}')

    echo "total_count=$total_count"
    echo "total_size=$total_size"
}

# 主入口
case "$1" in
    pull)
        pull_image "$2" "$3" "$4"
        ;;
    list)
        list_images
        ;;
    info)
        get_image_info "$2"
        ;;
    remove)
        remove_image "$2"
        ;;
    prune)
        prune_images
        ;;
    stats)
        get_image_stats
        ;;
    *)
        echo "Usage: $0 {pull <image> [mirror] [custom_mirror]|list|info <id>|remove <id>|prune|stats}"
        exit 1
        ;;
esac
