#!/bin/bash

# 引入 UCI 配置读取库
. /lib/functions.sh

STATE_FILE="/tmp/ota_state.json"

# --- 辅助函数：更新前端显示状态 ---
set_state() {
    echo "{\"state\": \"$1\", \"progress\": $2, \"msg\": \"$3\"}" > $STATE_FILE
}

# --- 辅助函数：插件备份逻辑 ---
backup_list() {
    set_state "BACKUP" 10 "正在备份插件列表..."
    # 提取用户安装的插件
    opkg list-installed | cut -f 1 -d ' ' | grep -E "^luci-app-|^luci-theme-|^luci-i18n-" > /etc/config/last_opkg_list
    
    # 将名单加入保留列表
    grep -q "/etc/config/last_opkg_list" /etc/sysupgrade.conf || echo "/etc/config/last_opkg_list" >> /etc/sysupgrade.conf
    
    # 创建开机自动恢复脚本
    cat << 'EOF' > /etc/uci-defaults/99-restore-plugins
#!/bin/sh
if [ -f /etc/config/last_opkg_list ]; then
    opkg update
    xargs opkg install < /etc/config/last_opkg_list
    rm /etc/config/last_opkg_list
    rm /etc/uci-defaults/99-restore-plugins
fi
exit 0
EOF
    chmod 755 /etc/uci-defaults/99-restore-plugins
    grep -q "/etc/uci-defaults/99-restore-plugins" /etc/sysupgrade.conf || echo "/etc/uci-defaults/99-restore-plugins" >> /etc/sysupgrade.conf
}

# ================= 开始执行主逻辑 =================

# 1. 接收 Lua 参数
SELECTED_FILE=$1

# 2. 读取 UCI 设置 (一次性读取所有配置)
config_load ota
config_get REPO_URL settings url ""
config_get BACKUP_PLUGINS settings backup_plugins "1"
config_get DOWNLOAD_PROXY settings download_proxy "0"
config_get CUSTOM_PROXY settings custom_proxy_url "https://mirror.ghproxy.com/"
config_get GITHUB_TOKEN settings github_token ""

if [ -z "$REPO_URL" ]; then
    set_state "ERROR" 0 "未配置 GitHub API 下载地址"
    exit 1
fi

# 3. 执行插件备份
[ "$BACKUP_PLUGINS" = "1" ] && backup_list

# 4. 自动识别当前硬件平台
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    PLATFORM_TARGET=$DISTRIB_TARGET
else
    PLATFORM_TARGET=$(uname -m)
fi

case "$PLATFORM_TARGET" in
    "x86/64") MATCH_KEYWORDS="combined-efi|combined" ;;
    "rockchip/armv8") MATCH_KEYWORDS="xiguapi-v3|sysupgrade" ;;
    *) MATCH_KEYWORDS="sysupgrade" ;;
esac

# 5. 获取 GitHub Release JSON
set_state "CHECKING" 20 "正在连接 GitHub (平台: $PLATFORM_TARGET)..."

AUTH_HEADER=""
[ -n "$GITHUB_TOKEN" ] && AUTH_HEADER="--header='Authorization: token $GITHUB_TOKEN'"

wget -qO /tmp/release.json $AUTH_HEADER --header='User-Agent: x' --timeout=10 "$REPO_URL"

if [ $? -ne 0 ]; then
    set_state "ERROR" 0 "获取 GitHub 版本失败"
    exit 1
fi

REMOTE_VER=$(jsonfilter -i /tmp/release.json -e '@.tag_name')
set_state "CHECKING" 35 "发现新版本: $REMOTE_VER，正在匹配固件..."

# 6. 提取下载链接
if [ -n "$SELECTED_FILE" ]; then
    RAW_URL=$(jsonfilter -i /tmp/release.json -e "@.assets[@.name='$SELECTED_FILE'].browser_download_url")
else
    RAW_URL=$(jsonfilter -i /tmp/release.json -e '@.assets[*].browser_download_url' | \
               grep -E "$MATCH_KEYWORDS" | grep -E "\.(img\.gz|img|bin)$" | head -n 1)
fi

if [ -z "$RAW_URL" ]; then
    set_state "ERROR" 0 "未找到适配的固件包"
    exit 1
fi

# 6.5 应用自定义加速代理 (逻辑修正)
DOWNLOAD_URL="$RAW_URL"
if [ "$DOWNLOAD_PROXY" = "1" ]; then
    # 确保 CUSTOM_PROXY 以后缀 / 结尾，如果用户没填斜杠则补上 (简单处理)
    case "$CUSTOM_PROXY" in
        */) DOWNLOAD_URL="${CUSTOM_PROXY}${RAW_URL}" ;;
        *)  DOWNLOAD_URL="${CUSTOM_PROXY}/${RAW_URL}" ;;
    esac
fi

# 7. 开始下载
set_state "DOWNLOADING" 50 "正在下载: ${RAW_URL##*/}"
rm -f /tmp/ota_firmware.img.gz
wget -O /tmp/ota_firmware.img.gz "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    set_state "ERROR" 0 "固件下载失败"
    exit 1
fi

# 8. 校验逻辑
set_state "CHECKING" 80 "正在校验固件完整性..."
FILE_SIZE=$(ls -s /tmp/ota_firmware.img.gz | awk '{print $1}')
if [ "$FILE_SIZE" -lt 1000 ]; then
    set_state "ERROR" 0 "校验失败：下载的文件异常"
    exit 1
fi

# 9. 准备刷写
set_state "FLASHING" 95 "固件就绪，正在同步磁盘..."
sync

set_state "SUCCESS" 100 "升级包已就绪，系统正在重启..."
sleep 5 

# 执行刷写
sysupgrade /tmp/ota_firmware.img.gz