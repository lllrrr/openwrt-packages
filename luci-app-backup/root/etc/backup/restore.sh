#!/bin/sh
# ============================================
# 智能备份恢复插件 - 核心恢复脚本
# 路径：/etc/backup/restore.sh
# 作用：接收前端传递的恢复任务，执行解压和解密恢复
# ============================================

# 配置
LOG_FILE="/tmp/restore.log"
PASSWORD_FILE="/usr/bin/backup-password"
MAX_RETRIES=3
RETRY_DELAY=2

# 创建日志目录
> $LOG_FILE

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
    echo "$1" >&2
}

# 错误处理函数
error_exit() {
    log "错误: $1"
    echo "{\"success\":false,\"message\":\"$1\"}"
    exit 1
}

# 检查必要工具
check_requirements() {
    log "检查必要工具..."
    
    # 检查gpg
    if ! command -v gpg >/dev/null 2>&1; then
        log "警告: GPG未安装，尝试安装..."
        if opkg update && opkg install gnupg; then
            log "GPG安装成功"
        else
            error_exit "无法安装GPG，请手动安装: opkg install gnupg"
        fi
    fi
    
    # 检查tar
    if ! command -v tar >/dev/null 2>&1; then
        error_exit "系统缺少tar工具"
    fi
    
    # 检查jsonfilter
    if ! command -v jsonfilter >/dev/null 2>&1; then
        error_exit "系统缺少jsonfilter工具，请安装: opkg install jsonfilter"
    fi
    
    log "必要工具检查完成"
}

# 检查密码文件
check_password() {
    local password="$1"
    
    # 如果前端传入了密码，优先使用
    if [ -n "$password" ] && [ "$password" != "null" ]; then
        log "使用前端传入的密码"
        echo "$password" > /tmp/restore_password_tmp
        PASSWORD_FILE="/tmp/restore_password_tmp"
        return 0
    fi
    
    # 否则使用系统密码文件
    if [ ! -f "$PASSWORD_FILE" ]; then
        log "错误: 密码文件 $PASSWORD_FILE 不存在"
        return 1
    fi
    
    if [ ! -s "$PASSWORD_FILE" ]; then
        log "错误: 密码文件为空"
        return 1
    fi
    
    log "使用系统密码文件: $PASSWORD_FILE"
    return 0
}

# 检查文件完整性（针对加密文件）
check_gpg_integrity() {
    local file="$1"
    local password_file="$2"
    
    log "检查加密文件完整性: $file"
    
    if ! gpg --batch --passphrase-file "$password_file" --list-only "$file" >/dev/null 2>&1; then
        log "错误: 加密文件损坏或密码错误"
        return 1
    fi
    
    log "加密文件完整性检查通过"
    return 0
}

# 检查tar文件完整性
check_tar_integrity() {
    local file="$1"
    
    log "检查tar文件完整性: $file"
    
    if ! tar -tzf "$file" >/dev/null 2>&1; then
        log "错误: tar文件损坏"
        return 1
    fi
    
    log "tar文件完整性检查通过"
    return 0
}

# 解密并恢复单个文件
restore_single_file() {
    local file_path="$1"
    local need_decrypt="$2"
    local password_file="$3"
    local file_name=$(basename "$file_path")
    local temp_dir="/tmp/restore_$$_$(date +%s)"
    local temp_file=""
    local result=1
    
    log "开始处理文件: $file_name"
    log "文件路径: $file_path"
    log "需要解密: $need_decrypt"
    
    # 检查文件是否存在
    if [ ! -f "$file_path" ]; then
        log "错误: 文件不存在: $file_path"
        return 1
    fi
    
    # 检查文件大小
    local file_size=$(ls -l "$file_path" | awk '{print $5}')
    if [ "$file_size" -eq 0 ]; then
        log "错误: 文件为空: $file_path"
        return 1
    fi
    log "文件大小: $(du -h "$file_path" | cut -f1)"
    
    # 创建临时目录
    mkdir -p "$temp_dir"
    
    # 处理加密文件
    if [ "$need_decrypt" = "true" ]; then
        temp_file="$temp_dir/${file_name%.gpg}"
        log "解密文件到: $temp_file"
        
        # 先检查加密文件完整性
        if ! check_gpg_integrity "$file_path" "$password_file"; then
            log "错误: 加密文件完整性检查失败"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # 执行解密
        if gpg --batch --passphrase-file "$password_file" -d "$file_path" > "$temp_file" 2>> $LOG_FILE; then
            log "解密成功"
            file_path="$temp_file"
        else
            log "错误: 解密失败"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    # 检查tar文件完整性
    if ! check_tar_integrity "$file_path"; then
        log "错误: tar文件完整性检查失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 获取文件列表（预览）
    log "备份文件包含的内容:"
    tar -tzf "$file_path" | head -20 | while read line; do
        log "  $line"
    done
    
    local total_files=$(tar -tzf "$file_path" 2>/dev/null | wc -l)
    log "总共包含 $total_files 个文件/目录"
    
    # 执行恢复
    log "开始恢复文件到根目录 /"
    if tar -xzf "$file_path" -C / 2>> $LOG_FILE; then
        log "文件恢复成功"
        result=0
    else
        log "错误: 文件恢复失败"
        result=1
    fi
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    return $result
}

# 主恢复函数
main() {
    log "=========================================="
    log "开始处理恢复请求"
    
    # 读取输入数据
    local input_data=$(cat)
    log "接收到原始数据: $input_data"
    
    # 检查输入数据
    [ -z "$input_data" ] && error_exit "没有接收到恢复数据"
    
    # 解析JSON数据
    local files=$(echo "$input_data" | jsonfilter -e '@.files')
    local decrypt=$(echo "$input_data" | jsonfilter -e '@.decrypt')
    local password=$(echo "$input_data" | jsonfilter -e '@.password')
    
    log "解密选项: $decrypt"
    log "密码: ${password:+"已提供"}"
    
    # 检查文件列表
    if [ -z "$files" ] || [ "$files" = "null" ] || [ "$files" = "[]" ]; then
        error_exit "没有选择要恢复的文件"
    fi
    
    # 获取文件数量
    local file_count=$(echo "$input_data" | jsonfilter -e '@.files.length()' 2>/dev/null)
    if [ -z "$file_count" ] || [ "$file_count" -eq 0 ]; then
        file_count=$(echo "$files" | grep -o '"' | wc -l)
        file_count=$((file_count / 2))
    fi
    
    log "选择了 $file_count 个文件"
    
    # 检查必要工具
    check_requirements
    
    # 检查密码
    if [ "$decrypt" = "true" ]; then
        if ! check_password "$password"; then
            error_exit "密码检查失败，无法解密加密文件"
        fi
    fi
    
    # 遍历处理每个文件
    local success_count=0
    local fail_count=0
    local i=0
    
    while [ $i -lt $file_count ]; do
        log "处理文件索引: $i"
        
        # 提取文件路径
        local file_path=$(echo "$input_data" | jsonfilter -e "@.files[$i]")
        file_path=$(echo "$file_path" | sed 's/^"//;s/"$//')
        
        log "文件路径: $file_path"
        
        if [ -n "$file_path" ] && [ "$file_path" != "null" ]; then
            # 判断是否需要解密（根据文件扩展名）
            local need_decrypt="false"
            if [ "$decrypt" = "true" ] || echo "$file_path" | grep -q '\.gpg$'; then
                need_decrypt="true"
            fi
            
            # 恢复文件
            if restore_single_file "$file_path" "$need_decrypt" "$PASSWORD_FILE"; then
                success_count=$((success_count + 1))
                log "文件 $file_path 恢复成功"
            else
                fail_count=$((fail_count + 1))
                log "文件 $file_path 恢复失败"
            fi
        else
            log "跳过空文件路径"
        fi
        
        i=$((i + 1))
    done
    
    # 清理临时密码文件
    [ -f "/tmp/restore_password_tmp" ] && rm -f "/tmp/restore_password_tmp"
    
    # 返回结果
    local message=""
    local success="true"
    
    if [ $success_count -gt 0 ] && [ $fail_count -eq 0 ]; then
        message="所有 $success_count 个文件恢复成功"
    elif [ $success_count -gt 0 ] && [ $fail_count -gt 0 ]; then
        message="$success_count 个文件成功，$fail_count 个文件失败"
    elif [ $success_count -eq 0 ] && [ $fail_count -gt 0 ]; then
        message="所有 $fail_count 个文件均恢复失败"
        success="false"
    else
        message="没有处理任何文件"
        success="false"
    fi
    
    log "恢复处理完成: $message"
    echo "{\"success\":$success,\"message\":\"$message\"}"
}

# 执行主函数
main
exit $?