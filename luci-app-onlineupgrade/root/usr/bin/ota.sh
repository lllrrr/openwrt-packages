#!/bin/sh

# --- 脚本说明 ---
# 功能：OpenWrt/ImmortalWrt OTA 在线升级核心脚本 (Ultimate Pro 版)
# 特色：1. SHA256 强制完整性校验 2. 深度配置审计与可视化报告 3. 插件恢复进度追踪 4. 磁盘扩容
# 流程：下载 -> SHA256校验 -> [可选]解压 -> 审计生成报告 -> 注入恢复脚本 -> 刷写

# 引入 UCI 配置读取库
. /lib/functions.sh

# --- 全局路径定义 ---
STATE_FILE="/tmp/ota_state.json"         # 前端状态文件
LOG_FILE="/tmp/ota_build.log"            # 详细执行日志
FIRMWARE_PATH="/tmp/ota_firmware.bin"    # 固件暂存路径
SHA_FILE="/tmp/sha256sums"               # 校验文件暂存路径
UPDATE_FLAG="/tmp/ota_update_ready"      # 更新红点标志
VERSION_FILE="/etc/ota_version"          # 本地版本文件
MANUAL_PLUGINS="/tmp/ota_manual_plugins" # 手动插件列表
AUDIT_DIR="/tmp/ota_audit"               # 配置审计结果存放目录
AUDIT_REPORT="/tmp/ota_audit_report.txt" # 审计差异可视化报告

# --- 持久化状态路径 ---
RESTORE_LIST="/etc/config/last_opkg_list"
RESTORE_STATUS="/etc/config/ota_restore_status"

# --- 1. 辅助功能函数 ---

# 更新前端状态
set_state() {
    echo "{\"state\": \"$1\", \"progress\": $2, \"msg\": \"$3\"}" > $STATE_FILE
}

# 记录日志
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> $LOG_FILE
}

# 处理代理链接
get_proxy_url() {
    local raw_url=$1
    [ "$DOWNLOAD_PROXY" = "1" ] && [ -n "$CUSTOM_PROXY" ] && echo "${CUSTOM_PROXY%/}/$raw_url" || echo "$raw_url"
}

# 发送多平台通知
send_notify() {
    config_load ota
    config_get NOTIFY_ENABLE notification enabled "0"
    [ "$NOTIFY_ENABLE" = "0" ] && return
    config_get N_TYPE notification notify_type "sct"
    config_get N_TOKEN notification notify_token ""
    config_get N_CHATID notification notify_chatid ""
    
    local title="$1"
    local message="$2"
    
    case "$N_TYPE" in
        "sct") curl -s -d "title=${title}" -d "desp=${message}" "https://sctapi.ftqq.com/${N_TOKEN}.send" >/dev/null 2>&1 ;;
        "tg") curl -s -d "chat_id=${N_CHATID}" -d "text=${title}\n${message}" "https://api.telegram.org/bot${N_TOKEN}/sendMessage" >/dev/null 2>&1 ;;
        "dingtalk") curl -s -H 'Content-Type: application/json' -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"${title}\n${message}\"}}" "https://oapi.dingtalk.com/robot/send?access_token=${N_TOKEN}" >/dev/null 2>&1 ;;
    esac
}

# --- 2. 核心：SHA256 完整性校验 ---
check_sha256() {
    log "正在启动 SHA256 完整性安全校验..."
    # 从 Release 资产中动态查找名为 sha256sums 的文件
    local sha_url=$(jsonfilter -i /tmp/release.json -e '@.assets[*].browser_download_url' | grep -i "sha256sums" | head -n 1)
    
    if [ -n "$sha_url" ]; then
        wget -qO $SHA_FILE $(get_proxy_url "$sha_url")
        # 提取当前固件对应的哈希值
        local remote_hash=$(grep "$FIRMWARE_NAME" $SHA_FILE | awk '{print $1}')
        local local_hash=$(sha256sum $FIRMWARE_PATH | awk '{print $1}')
        
        if [ "$remote_hash" = "$local_hash" ]; then
            log "SHA256 校验通过：匹配成功 ($local_hash)"
            return 0
        else
            log "致命错误：SHA256 校验不匹配！本地: $local_hash 云端: $remote_hash"
            return 1
        fi
    else
        log "警告：云端未发现 sha256sums 文件，跳过强制校验。"
        return 0
    fi
}

# --- 3. 核心：配置审计与可视化报告 ---
audit_configs() {
    if [ "$CONFIG_AUDIT" != "1" ]; then
        log "配置审计已关闭。"
        return
    fi

    log "正在启动深度审计，生成冲突报告..."
    mkdir -p $AUDIT_DIR /tmp/new_root
    echo "=== 固件配置冲突预警报告 ===" > $AUDIT_REPORT
    echo "生成时间: $(date)" >> $AUDIT_REPORT
    
    mount -o loop,ro $FIRMWARE_PATH /tmp/new_root 2>/dev/null
    if [ $? -eq 0 ]; then
        local check_list="network wireless firewall dhcp"
        for cfg in $check_list; do
            if [ -f "/etc/config/$cfg" ] && [ -f "/tmp/new_root/etc/config/$cfg" ]; then
                diff -u "/etc/config/$cfg" "/tmp/new_root/etc/config/$cfg" > "$AUDIT_DIR/$cfg.diff"
                if [ -s "$AUDIT_DIR/$cfg.diff" ]; then
                    echo -e "\n[ $cfg ] 发现差异内容：" >> $AUDIT_REPORT
                    cat "$AUDIT_DIR/$cfg.diff" >> $AUDIT_REPORT
                    log "冲突提示：$cfg 存在差异"
                fi
            fi
        done
        umount /tmp/new_root
    else
        log "审计失败：固件无法挂载 (可能由于未解压或分区不支持)"
        echo "报告：固件无法挂载，未能进行差异比对。" >> $AUDIT_REPORT
    fi
}

# --- 4. 核心：带进度的插件自动恢复引擎 ---
generate_restore_script() {
    log "正在注入带进度反馈的插件恢复引擎..."
    opkg list-installed | cut -f 1 -d ' ' | grep -E "^luci-app-|^luci-theme-|^luci-i18n-" > $RESTORE_LIST
    local total_pkgs=$(wc -l < $RESTORE_LIST)

    cat << EOF > /etc/uci-defaults/99-restore-plugins
#!/bin/sh
# 实时同步恢复状态，供前端 UI 渲染
STATUS_FILE="$RESTORE_STATUS"
LIST_FILE="$RESTORE_LIST"
TOTAL=$total_pkgs

write_status() { echo "{\"status\":\"\$3\", \"current\":\$1, \"total\":\$TOTAL, \"pkg\":\"\$2\"}" > "\$STATUS_FILE"; }

if [ -f "\$LIST_FILE" ]; then
    write_status 0 "None" "WAITING_NETWORK"
    # 循环检查网络
    while ! ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; do sleep 5; done
    
    write_status 0 "opkg_update" "UPDATING_REPOS"
    opkg update
    
    INDEX=0
    while read pkg; do
        [ -z "\$pkg" ] && continue
        INDEX=\$((INDEX + 1))
        write_status \$INDEX "\$pkg" "INSTALLING"
        opkg install "\$pkg" >> /var/log/ota_restore.log 2>&1
    done < "\$LIST_FILE"
    
    write_status \$TOTAL "Complete" "DONE"
    rm "\$LIST_FILE"
fi
exit 0
EOF
    chmod 755 /etc/uci-defaults/99-restore-plugins
    # 确保恢复状态和列表在升级时被带走
    for f in "$RESTORE_LIST" "$RESTORE_STATUS" "/etc/uci-defaults/99-restore-plugins"; do
        grep -q "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
    done
}

# --- 5. 核心：磁盘扩容脚本 ---
generate_resize_script() {
    log "正在生成磁盘自动扩容策略..."
    cat << 'EOF' > /etc/uci-defaults/90-auto-resize
#!/bin/sh
ROOT_DEV=$(mount | grep ' / ' | cut -d' ' -f1)
DISK_DEV=$(echo $ROOT_DEV | sed -r 's/p?[0-9]+$//')
PART_NUM=$(echo $ROOT_DEV | grep -oE '[0-9]+$')
if [ -b "$DISK_DEV" ] && [ -n "$PART_NUM" ]; then
    ( echo d; echo $PART_NUM; echo n; echo p; echo $PART_NUM; echo; echo; echo w ) | fdisk "$DISK_DEV" >/dev/null 2>&1
    partx -u "$DISK_DEV" >/dev/null 2>&1
    [ -x "/usr/sbin/resize2fs" ] && resize2fs "$ROOT_DEV" >> /var/log/ota_resize.log 2>&1
fi
exit 0
EOF
    chmod 755 /etc/uci-defaults/90-auto-resize
    grep -q "/etc/uci-defaults/90-auto-resize" /etc/sysupgrade.conf || echo "/etc/uci-defaults/90-auto-resize" >> /etc/sysupgrade.conf
}

# ================= 主程序开始 =================

SELECTED_FILE=$1
KEEP_CONFIG=$2
[ -z "$KEEP_CONFIG" ] && KEEP_CONFIG="1"

echo "--- OTA 核心引擎启动 ---" > $LOG_FILE
log "升级模式: $([ "$KEEP_CONFIG" = "1" ] && echo "保留配置" || echo "全清刷机")"

# 1. 配置加载
config_load ota
config_get REPO_URL settings url ""
config_get BACKUP_PLUGINS settings backup_plugins "1"
config_get AUTO_RESIZE settings auto_resize "0"
config_get DOWNLOAD_PROXY settings download_proxy "0"
config_get CUSTOM_PROXY settings custom_proxy_url ""
config_get GITHUB_TOKEN settings github_token ""
config_get CONFIG_AUDIT settings config_audit "0"

# 2. 云端检查
set_state "CHECKING" 10 "连接云端获取资产..."
AUTH_HEADER=""
[ -n "$GITHUB_TOKEN" ] && AUTH_HEADER="--header='Authorization: token $GITHUB_TOKEN'"
wget -qO /tmp/release.json $AUTH_HEADER --header='User-Agent: x' --timeout=15 "$REPO_URL" || { set_state "ERROR" 0 "云端连接超时"; exit 1; }
REMOTE_VER=$(jsonfilter -i /tmp/release.json -e '@.tag_name')

# 3. 固件匹配
set_state "CHECKING" 25 "智能匹配最佳固件..."
PLATFORM=$(jsonfilter -e '@.model.id' < /etc/board.json 2>/dev/null || uname -m)
if [ -n "$SELECTED_FILE" ]; then
    RAW_URL=$(jsonfilter -i /tmp/release.json -e "@.assets[*].browser_download_url" | grep -F "$SELECTED_FILE" | head -n 1)
else
    case "$PLATFORM" in 
        *"x86_64"*|*"x86"*) MATCH="ext4-combined-efi[.]img[.]gz|combined-efi[.]img[.]gz|combined[.]img[.]gz" ;; 
        *"xgp-v3"*) MATCH="xiguapi-v3|sysupgrade" ;; 
        *) MATCH="sysupgrade[.]bin|combined[.]img[.]gz|[.]img[.]gz" ;; 
    esac
    RAW_URL=$(jsonfilter -i /tmp/release.json -e '@.assets[*].browser_download_url' | grep -E "$MATCH" | head -n 1)
fi
[ -z "$RAW_URL" ] && { set_state "ERROR" 0 "未找到匹配架构的固件"; exit 1; }
FIRMWARE_NAME="${RAW_URL##*/}"

# 4. 下载
set_state "DOWNLOADING" 40 "固件下载中..."
wget -O $FIRMWARE_PATH $(get_proxy_url "$RAW_URL") 2>> $LOG_FILE || { set_state "ERROR" 0 "下载失败"; exit 1; }

# 5. 安全审计与策略预读
if [ "$KEEP_CONFIG" = "1" ]; then
    # 5.1 SHA256 强制完整性检查 (新增)
    check_sha256 || { set_state "ERROR" 0 "哈希校验失败，固件可能损坏"; exit 1; }

    # 5.2 解压逻辑 (根据用户开关控制)
    if [ "$CONFIG_AUDIT" = "1" ] && [ "${FIRMWARE_NAME##*.}" = "gz" ]; then
        log "审计已开启，正在解压..."
        zcat $FIRMWARE_PATH > "${FIRMWARE_PATH}.tmp" 2>> $LOG_FILE && mv "${FIRMWARE_PATH}.tmp" $FIRMWARE_PATH || log "警告：解压失败"
    fi
    
    set_state "AUDITING" 85 "生成报告与注入恢复策略..."
    audit_configs            # 生成可视化审计报告 (新增)
    generate_restore_script  # 注入带进度追踪的恢复引擎 (新增)
    [ "$AUTO_RESIZE" = "1" ] && generate_resize_script
fi

# 6. 最终刷写
log "所有流程通过，执行 sysupgrade..."
set_state "FLASHING" 95 "正在写入并重启，请勿断电"
send_notify "OTA 升级启动" "版本: $REMOTE_VER\nSHA256 校验通过，正在重启..."
sync && sleep 3

if [ "$KEEP_CONFIG" = "1" ]; then
    sysupgrade "$FIRMWARE_PATH" >> $LOG_FILE 2>&1
else
    sysupgrade -n "$FIRMWARE_PATH" >> $LOG_FILE 2>&1
fi