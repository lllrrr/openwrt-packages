#!/bin/sh

# ============================================
# 智能备份恢复插件 - 核心备份脚本
# 路径：/etc/backup/backup.sh
# 作用：接收前端传递的备份任务，执行打包和加密
# ============================================

# 配置
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/tmp/backup.log"
PASSWORD_FILE="/usr/bin/backup-password"

# 清空日志
> $LOG_FILE

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# 错误处理函数
error_exit() {
    log "错误: $1"
    echo "{\"success\":false,\"message\":\"$1\"}"
    exit 1
}

# 检查必要文件
[ -f "$PASSWORD_FILE" ] || log "警告: 密码文件不存在"

# 读取所有输入数据
log "开始处理备份请求"
input_data=$(cat)
log "接收到原始数据: $input_data"

# 检查输入数据
[ -z "$input_data" ] && error_exit "没有接收到备份数据"

# 检查jsonfilter是否可用
if ! command -v jsonfilter >/dev/null 2>&1; then
    error_exit "系统缺少jsonfilter工具，请安装: opkg install jsonfilter"
fi

# 提取备份目录 - 新增
BACKUP_DIR=$(echo "$input_data" | jsonfilter -e '@.backup_dir' 2>/dev/null)
if [ -z "$BACKUP_DIR" ] || [ "$BACKUP_DIR" = "null" ]; then
    BACKUP_DIR="/tmp/backup"
fi
log "备份目录: $BACKUP_DIR"

# 创建备份目录
mkdir -p $BACKUP_DIR

# 提取加密选项
encrypt=$(echo "$input_data" | jsonfilter -e '@.encrypt')
log "加密选项: $encrypt"

# 提取任务数组
tasks_json=$(echo "$input_data" | jsonfilter -e '@.tasks')
log "任务JSON: $tasks_json"

# 检查是否有任务数据
if [ -z "$tasks_json" ] || [ "$tasks_json" = "null" ] || [ "$tasks_json" = "[]" ]; then
    error_exit "没有找到有效的任务数据"
fi

# 获取任务数量 - 使用多种方法
task_count=$(echo "$input_data" | jsonfilter -e '@.tasks.length()' 2>/dev/null)
if [ -z "$task_count" ] || [ "$task_count" -eq 0 ]; then
    # 备选方法：统计任务对象数量
    task_count=$(echo "$tasks_json" | grep -o '"name"' | wc -l)
fi

log "找到 $task_count 个任务"

if [ -z "$task_count" ] || [ "$task_count" -eq 0 ]; then
    error_exit "无法确定任务数量"
fi

# 遍历任务
success_count=0
fail_count=0
i=0

while [ $i -lt $task_count ]; do
    log "处理任务索引: $i"
    
    # 提取任务名称
    task_name=$(echo "$input_data" | jsonfilter -e "@.tasks[$i].name")
    
    # 去除可能的引号
    task_name=$(echo "$task_name" | sed 's/^"//;s/"$//')
    
    log "任务名称: $task_name"
    
    if [ -z "$task_name" ] || [ "$task_name" = "null" ]; then
        log "跳过空任务"
        i=$((i + 1))
        continue
    fi
    
    # 获取该任务的文件列表
    files_json=$(echo "$input_data" | jsonfilter -e "@.tasks[$i].files")
    log "任务 $task_name 的文件JSON: $files_json"
    
    # 获取文件数量
    file_count=$(echo "$input_data" | jsonfilter -e "@.tasks[$i].files.length()" 2>/dev/null)
    if [ -z "$file_count" ] || [ "$file_count" -eq 0 ]; then
        # 备选方法：统计文件数量
        file_count=$(echo "$files_json" | grep -o '"' | wc -l)
        file_count=$((file_count / 2))
    fi
    
    log "任务 $task_name 有 $file_count 个文件"
    
    if [ -n "$file_count" ] && [ "$file_count" -gt 0 ]; then
        # 生成安全的文件名
        safe_name=$(echo "$task_name" | tr ' /\\' '___' | tr -d '\"\'"'")
        backup_file="$BACKUP_DIR/${safe_name}_${TIMESTAMP}.tar.gz"
        
        log "备份文件: $backup_file"
        
        # 构建文件列表
        tar_files=""
        valid_file_count=0
        missing_files=""
        
        j=0
        while [ $j -lt $file_count ]; do
            # 提取文件路径
            file=$(echo "$input_data" | jsonfilter -e "@.tasks[$i].files[$j]")
            
            # 去除可能的引号
            file=$(echo "$file" | sed 's/^"//;s/"$//')
            
            if [ -n "$file" ] && [ "$file" != "null" ]; then
                log "检查文件: $file"
                
                if [ -e "$file" ]; then
                    # 正确处理带空格的文件名
                    tar_files="$tar_files \"$file\""
                    valid_file_count=$((valid_file_count + 1))
                    log "文件存在: $file"
                else
                    log "警告: 文件不存在 - $file"
                    if [ -z "$missing_files" ]; then
                        missing_files="$file"
                    else
                        missing_files="$missing_files, $file"
                    fi
                fi
            fi
            j=$((j + 1))
        done
        
        log "任务 $task_name: 找到 $valid_file_count 个有效文件，缺失: $missing_files"
        
        if [ $valid_file_count -eq 0 ]; then
            log "任务 $task_name: 没有有效文件可备份"
            fail_count=$((fail_count + 1))
            i=$((i + 1))
            continue
        fi
        
        # 执行备份
        log "执行tar命令: tar -czf \"$backup_file\" $tar_files"
        
        # 使用sh -c执行命令，避免eval的问题
        tar_cmd="tar -czf \"$backup_file\" $tar_files"
        sh -c "$tar_cmd" 2>> $LOG_FILE
        tar_result=$?
        
        if [ $tar_result -eq 0 ] && [ -f "$backup_file" ]; then
            file_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
            log "任务 $task_name: 打包成功，文件大小: $file_size"
            
            # 如果需要加密
            if [ "$encrypt" = "true" ] && [ -f "$PASSWORD_FILE" ]; then
                password=$(cat "$PASSWORD_FILE")
                encrypted_file="${backup_file}.gpg"
                
                log "执行加密: $encrypted_file"
                echo "$password" | gpg --batch --yes --passphrase-fd 0 -c --cipher-algo AES256 -o "$encrypted_file" "$backup_file" 2>> $LOG_FILE
                gpg_result=$?
                
                if [ $gpg_result -eq 0 ] && [ -f "$encrypted_file" ]; then
                    rm -f "$backup_file"
                    log "任务 $task_name: 加密成功"
                    success_count=$((success_count + 1))
                else
                    log "任务 $task_name: 加密失败，保留未加密文件"
                    success_count=$((success_count + 1))
                fi
            else
                log "任务 $task_name: 备份成功（未加密）"
                success_count=$((success_count + 1))
            fi
        else
            log "任务 $task_name: 打包失败 (错误码: $tar_result)"
            fail_count=$((fail_count + 1))
        fi
    else
        log "任务 $task_name: 没有文件可备份"
        fail_count=$((fail_count + 1))
    fi
    
    i=$((i + 1))
done

# 返回结果
if [ $success_count -gt 0 ] && [ $fail_count -eq 0 ]; then
    echo "{\"success\":true,\"message\":\"所有 $success_count 个任务备份成功\",\"file\":\"$BACKUP_DIR\"}"
elif [ $success_count -gt 0 ] && [ $fail_count -gt 0 ]; then
    echo "{\"success\":true,\"message\":\"$success_count 个任务成功，$fail_count 个任务失败\",\"file\":\"$BACKUP_DIR\"}"
elif [ $success_count -eq 0 ] && [ $fail_count -gt 0 ]; then
    echo "{\"success\":false,\"message\":\"所有 $fail_count 个任务均失败\"}"
else
    echo "{\"success\":false,\"message\":\"没有可备份的任务\"}"
fi

log "备份处理完成，成功: $success_count, 失败: $fail_count"