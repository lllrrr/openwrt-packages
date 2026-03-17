-- OpenVPN管理控制器
-- 项目已更名为luci-app-openvpn-admin
module("luci.controller.openvpn-admin", package.seeall)

local require = require
local http = require("luci.http")
local sys = require("luci.sys")
local util = require("luci.util")
local json = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local nixio = require("nixio")

-- 全局配置缓存
local admin_config = nil

-- 获取管理配置（带缓存）
function get_admin_config()
    if admin_config then
        return admin_config
    end
    
    -- 统一配置默认值
    admin_config = {
        openvpn_instance = "myvpn",
        openvpn_config_path = "/etc/config/openvpn",
        refresh_enabled = true,
        refresh_interval = 1,
        history_size = 20,
        blacklist_enabled = true,
        blacklist_duration = 300,
        log_file = "/tmp/openvpn.log",
        history_file = "/etc/openvpn/openvpn_connection_history.json",
        blacklist_file = "/etc/openvpn/blacklist.json",
        easyrsa_dir = "/etc/easy-rsa",
        easyrsa_pki = "/etc/easy-rsa/pki",
        openvpn_pki = "/etc/openvpn/pki",
        
        -- 日志页面配置
        logs_refresh_enabled = true,
        logs_refresh_interval = 10,
        logs_display_lines = 1000,
        
        -- 脚本路径配置
        generate_client_script = "/etc/openvpn/generate-client.sh",
        renew_cert_script = "/etc/openvpn/renewcert.sh",
        
        -- 配置项
        temp_dir = "/tmp/openvpn-admin",
        clean_garbage_enabled = false,
        clean_garbage_time = "4:50",
        clean_garbage_script = "/etc/openvpn/clean-garbage.sh",
        
        -- 新增hotplug配置
        hotplug_enabled = false,
        hotplug_interface = "",
        hotplug_ipv6_interface = "auto",
        hotplug_ipv6_address = "",
        hotplug_script_path = "/etc/openvpn/openvpn_hotplug.sh",
        
        -- 新增hotplug防火墙配置
        hotplug_firewall_enabled = false,
        hotplug_firewall_name = "openvpn_ipv6",
        
        -- IPv6脚本配置
        ipv6_script_path = "/etc/openvpn/openvpn_ipv6",
        ipv6_script_interval = 10,  -- 默认10分钟
        ipv6_script_enabled = false -- 默认禁用
    }
    
    -- 尝试从uci配置中读取
    local uci_section = uci:get_first("openvpn-admin", "settings")
    
    if uci_section then
        local configs = {
            "openvpn_instance", "openvpn_config_path", "refresh_enabled", 
            "refresh_interval", "history_size", "blacklist_enabled", 
            "blacklist_duration", "log_file", "history_file", "blacklist_file",
            "easyrsa_dir", "easyrsa_pki", "openvpn_pki",
            "logs_refresh_enabled", "logs_refresh_interval", "logs_display_lines",
            "generate_client_script", "renew_cert_script",
            -- 新增配置项
            "temp_dir", "clean_garbage_enabled", "clean_garbage_time",
            "clean_garbage_script",
            -- IPv6脚本配置
            "ipv6_script_path", "ipv6_script_interval", "ipv6_script_enabled",
            -- 新增hotplug配置项
            "hotplug_enabled", "hotplug_interface", "hotplug_ipv6_interface",  
            "hotplug_ipv6_address", "hotplug_script_path",
            
            -- 新增hotplug防火墙配置项
            "hotplug_firewall_enabled", "hotplug_firewall_name"
        }
        
        for _, key in ipairs(configs) do
    local value = uci:get("openvpn-admin", uci_section, key)
    if value then
        if key == "refresh_enabled" or key == "blacklist_enabled" or 
           key == "logs_refresh_enabled" or key == "clean_garbage_enabled" or
           key == "ipv6_script_enabled" or key == "hotplug_enabled"  or
           key == "hotplug_firewall_enabled" then
            admin_config[key] = (value == "1")
        -- 处理数值转换
                elseif key == "refresh_interval" or key == "history_size" or 
                       key == "blacklist_duration" or key == "logs_refresh_interval" or 
                       key == "logs_display_lines" or key == "ipv6_script_interval" then
            admin_config[key] = tonumber(value)
        else
            admin_config[key] = value
        end
    end
end
    end
    
    return admin_config
end

-- 获取OpenVPN实例名称
function get_openvpn_instance()
    local config = get_admin_config()
    return config.openvpn_instance
end

-- 获取OpenVPN配置文件路径
function get_openvpn_config_path()
    local config = get_admin_config()
    return config.openvpn_config_path
end

-- 获取刷新间隔
function get_refresh_interval()
    local config = get_admin_config()
    if config.refresh_enabled then
        return config.refresh_interval
    end
    return 0  -- 禁用自动刷新
end

-- 设置OpenVPN服务状态（统一函数）
function set_openvpn_service_state(enable)
    local instance = get_openvpn_instance()
    local result = {
        success = false,
        message = ""
    }
    
    -- 1. 更新UCI配置
    local ok, err = pcall(function()
        uci:set("openvpn", instance, "enabled", enable and "1" or "0")
        uci:save("openvpn")
        uci:commit("openvpn")
    end)
    
    if not ok then
        result.message = "更新配置失败: " .. tostring(err)
        return result
    end
    
    -- 2. 执行服务操作
    local cmd = enable and "start" or "stop"
    local ret = sys.call("/etc/init.d/openvpn " .. cmd .. " >/dev/null 2>&1")
    
    if ret == 0 then
        result.success = true
        result.message = enable and "OpenVPN服务已启用并启动" or "OpenVPN服务已停止并禁用"
    else
        result.message = enable and "服务启动失败" or "服务停止失败"
    end
    
    return result
end

-- 获取历史记录行数
function get_history_size()
    local config = get_admin_config()
    return config.history_size or 20
end

-- 获取黑名单配置
function get_blacklist_config()
    local config = get_admin_config()
    return {
        enabled = config.blacklist_enabled,
        duration = config.blacklist_duration,
        file = config.blacklist_file
    }
end

-- 获取日志文件路径
function get_log_file()
    local config = get_admin_config()
    return config.log_file
end

-- 获取历史文件路径
function get_history_file()
    local config = get_admin_config()
    return config.history_file
end

-- 获取证书相关路径
function get_cert_paths()
    local config = get_admin_config()
    return {
        easyrsa_dir = config.easyrsa_dir,
        easyrsa_pki = config.easyrsa_pki,
        openvpn_pki = config.openvpn_pki
    }
end

-- 获取脚本路径
function get_script_paths()
    local config = get_admin_config()
    return {
        generate_client_script = config.generate_client_script,
        renew_cert_script = config.renew_cert_script,
        clean_garbage_script = config.clean_garbage_script
    }
end

-- 获取日志页面配置
function get_logs_config()
    local config = get_admin_config()
    return {
        refresh_enabled = config.logs_refresh_enabled,
        refresh_interval = config.logs_refresh_interval or 10,
        display_lines = config.logs_display_lines or 1000
    }
end

-- 获取临时文件目录
function get_temp_dir()
    local config = get_admin_config()
    return config.temp_dir or "/tmp/openvpn-admin"
end

-- 更新cron任务
-- 清理cron文件中的特定关键词行
function clean_cron_lines(content, keywords)
    local new_lines = {}
    for line in content:gmatch("[^\r\n]+") do
        local skip = false
        
        -- 检查是否包含任何关键词
        for _, keyword in ipairs(keywords) do
            if line:match(keyword) then
                skip = true
                break
            end
        end
        
        if not skip then
            table.insert(new_lines, line)
        end
    end
    
    return new_lines
end

function update_cron_job()
    local config = get_admin_config()
    local cron_file = "/etc/crontabs/root"
    
    -- 读取现有的cron文件
    local cron_content = ""
    if sys.call("test -f " .. cron_file .. " 2>/dev/null") == 0 then
        cron_content = sys.exec("cat " .. cron_file .. " 2>/dev/null")
    end
    
    -- 移除所有OpenVPN相关的行（包括注释）
    local keywords = {"[Oo]pen[Vv][Pp][Nn]", "clean%-garbage", "垃圾清理"}
    local new_lines = clean_cron_lines(cron_content, keywords)
    
    -- 只有在启用时才添加任务行（不加注释）
    if config.clean_garbage_enabled then
        local hour, minute = config.clean_garbage_time:match("(%d+):(%d+)")
        if not hour or not minute then
            hour, minute = "4", "50"
        end
        
        local script_path = config.clean_garbage_script or "/etc/openvpn/clean-garbage.sh"
        
        if sys.call("test -f " .. script_path .. " 2>/dev/null") ~= 0 then
            create_clean_garbage_script(script_path, config.temp_dir)
        end
        
        -- 只添加任务行，不加注释
        table.insert(new_lines, string.format("%s %s * * * %s", minute, hour, script_path))
    end
    
    -- 写入文件
    local temp_cron = "/tmp/root.cron.tmp"
    local fd = io.open(temp_cron, "w")
    if fd then
        fd:write(table.concat(new_lines, "\n"))
        fd:close()
        sys.exec("mv " .. temp_cron .. " " .. cron_file .. " 2>/dev/null")
        sys.exec("chmod 644 " .. cron_file .. " 2>/dev/null")
        sys.exec("/etc/init.d/cron restart 2>/dev/null")
        return true
    end
    return false
end

-- 修复：更新IPv6 cron任务 - 确保启用时添加，禁用时删除
function update_ipv6_cron_job()
    local config = get_admin_config()
    local cron_file = "/etc/crontabs/root"
    
    -- 读取现有的cron文件
    local cron_content = ""
    if sys.call("test -f " .. cron_file .. " 2>/dev/null") == 0 then
        cron_content = sys.exec("cat " .. cron_file .. " 2>/dev/null")
    end
    
    -- 移除所有IPv6相关的行（包括注释和任务行）
    -- 使用更精确的关键词匹配
    local keywords = {"[Ii][Pp][Vv]6", "openvpn[_-]ipv6", "ipv6[_-]script", "openvpn_ipv6"}
    local new_lines = clean_cron_lines(cron_content, keywords)
    
    -- 如果启用IPv6脚本，添加定时任务
    if config.ipv6_script_enabled and config.ipv6_script_path then
        local script_exists = sys.call("test -f " .. config.ipv6_script_path .. " 2>/dev/null") == 0
        
        if script_exists then
            -- 确保脚本有执行权限
            sys.exec("chmod +x " .. config.ipv6_script_path .. " 2>/dev/null")
            
            -- 添加定时任务行
            local cron_line = string.format("*/%d * * * * %s >/dev/null 2>&1", 
                config.ipv6_script_interval, config.ipv6_script_path)
            table.insert(new_lines, cron_line)
            
            nixio.syslog("info", "添加IPv6定时任务: " .. cron_line)
        else
            nixio.syslog("warning", "IPv6脚本不存在，无法添加定时任务: " .. config.ipv6_script_path)
        end
    else
        nixio.syslog("info", "IPv6脚本未启用，已移除所有相关定时任务")
    end
    
    -- 写入文件
    local temp_cron = "/tmp/root.cron.tmp"
    local fd = io.open(temp_cron, "w")
    if fd then
        -- 过滤空行
        local non_empty_lines = {}
        for _, line in ipairs(new_lines) do
            if line and line ~= "" then
                table.insert(non_empty_lines, line)
            end
        end
        
        fd:write(table.concat(non_empty_lines, "\n"))
        -- 确保文件以换行符结尾
        if #non_empty_lines > 0 then
            fd:write("\n")
        end
        fd:close()
        sys.exec("mv " .. temp_cron .. " " .. cron_file .. " 2>/dev/null")
        sys.exec("chmod 644 " .. cron_file .. " 2>/dev/null")
        sys.exec("/etc/init.d/cron restart 2>/dev/null")
        return true
    end
    return false
end



-- 运行IPv6脚本（如果启用）
function run_ipv6_script_if_enabled()
    local config = get_admin_config()
    
    if config.ipv6_script_enabled and config.ipv6_script_path then
        local script_exists = sys.call("test -f " .. config.ipv6_script_path .. " 2>/dev/null") == 0
        
        if script_exists then
            -- 确保脚本有执行权限
            sys.exec("chmod +x " .. config.ipv6_script_path .. " 2>/dev/null")
            
            -- 运行脚本并记录日志
            local output = sys.exec(config.ipv6_script_path .. " 2>&1")
            nixio.syslog("info", "OpenVPN IPv6脚本执行结果: " .. output)
            
            return true
        else
            nixio.syslog("warning", "IPv6脚本不存在: " .. config.ipv6_script_path)
            return false
        end
    end
    
    return nil  -- 表示脚本未启用
end

-- 创建垃圾清理脚本
function create_clean_garbage_script(script_path, temp_dir)
    local dir = script_path:match("^(.*/)[^/]*$")
    if dir then
        sys.exec("mkdir -p " .. dir .. " 2>/dev/null")
    end
    
    local script_content = [[
#!/bin/sh
# OpenVPN管理插件垃圾清理脚本

# 临时文件目录
TEMP_DIR="]] .. (temp_dir or "/tmp/openvpn-admin") .. [["

# 日志文件
LOG_FILE="/var/log/openvpn-admin-clean.log"

# 检查临时目录是否存在
if [ ! -d "$TEMP_DIR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 临时目录不存在: $TEMP_DIR" >> "$LOG_FILE"
    exit 1
fi

# 清理临时文件（保留最近1天的文件）
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 开始清理临时目录: $TEMP_DIR" >> "$LOG_FILE"

# 删除超过1天的临时文件
find "$TEMP_DIR" -type f -mtime +1 -delete 2>/dev/null

# 删除空目录
find "$TEMP_DIR" -type d -empty -delete 2>/dev/null

# 统计清理结果
REMAINING_FILES=$(find "$TEMP_DIR" -type f | wc -l)
REMAINING_DIRS=$(find "$TEMP_DIR" -type d | wc -l)

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 清理完成，剩余文件: $REMAINING_FILES，剩余目录: $REMAINING_DIRS" >> "$LOG_FILE"

# 限制日志文件大小
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 1048576 ]; then  # 大于1MB
        tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi

exit 0
]]
    
    local fd = io.open(script_path, "w")
    if fd then
        fd:write(script_content)
        fd:close()
        sys.exec("chmod +x " .. script_path .. " 2>/dev/null")
        return true
    end
    return false
end

-- 创建hotplug脚本
function create_hotplug_script(config)
    local script_path = config.hotplug_script_path or "/etc/openvpn/openvpn_hotplug.sh"
    local dir = script_path:match("^(.*/)[^/]*$")
    
    if dir then
        sys.exec("mkdir -p " .. dir .. " 2>/dev/null")
    end
    
    -- 获取OpenVPN实例名称
    local openvpn_instance = config.openvpn_instance or "myvpn"
    
    local script_content = [[
#!/bin/sh

# OpenVPN Hotplug IPv6地址更新脚本
# 自动检测网络接口变化并更新OpenVPN的IPv6地址
# 针对360t7设备优化版本

# 调试模式（0=关闭，1=开启）- 360t7建议关闭详细调试
DEBUG_MODE=0  # 关闭调试模式，减少日志输出

# 进程锁文件
LOCK_FILE="/tmp/openvpn_hotplug.lock"
SCRIPT_TIMEOUT=80  # 整个脚本最大执行时间（秒）

# 从配置文件读取设置
CONFIG_FILE="/etc/config/openvpn-admin"
OPENVPN_INSTANCE="myvpn"

# 简化日志函数
log_message() {
    local level="$1"
    local message="$2"
    
    # 在非调试模式下，只记录info、warning、error级别的日志
    if [ "$DEBUG_MODE" -eq 0 ] && [ "$level" = "debug" ]; then
        return
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp [$level] $message" >> /tmp/openvpn_hotplug.log
    
    # 简化日志文件大小限制
    if [ -f /tmp/openvpn_hotplug.log ] && \
       [ $(wc -l < /tmp/openvpn_hotplug.log 2>/dev/null) -gt 500 ]; then
        tail -250 /tmp/openvpn_hotplug.log > /tmp/openvpn_hotplug.log.tmp
        mv /tmp/openvpn_hotplug.log.tmp /tmp/openvpn_hotplug.log
    fi
}

# 进程锁检查
check_process_lock() {
    # 检查是否已有实例在运行
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_message "debug" "已有hotplug实例在运行(PID: $lock_pid)，退出当前实例"
            exit 0
        else
            # 清理无效的锁文件
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
}

# 清理函数
cleanup() {
    # 清理锁文件
    rm -f "$LOCK_FILE"
    log_message "debug" "清理进程锁"
}

# 超时检查函数
check_timeout() {
    local start_time="$1"
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    if [ $elapsed -ge $SCRIPT_TIMEOUT ]; then
        log_message "error" "脚本执行超时（超过 ${SCRIPT_TIMEOUT}秒），强制退出"
        cleanup
        exit 1
    fi
}

# 读取配置文件
get_config_value() {
    local key="$1"
    local default="$2"
    local value=$(uci -q get "$CONFIG_FILE.@settings[0].$key" 2>/dev/null)
    echo "${value:-$default}"
}

# 获取IPv6地址的/64前缀（简化版）
get_ipv6_prefix_64() {
    local ipv6_address="$1"
    
    if [ -z "$ipv6_address" ]; then
        echo ""
        return 1
    fi
    
    log_message "debug" "处理IPv6地址: $ipv6_address"
    
    # 方法1：简单提取前4段
    local prefix=$(echo "$ipv6_address" | cut -d: -f1-4)
    
    if [ -z "$prefix" ]; then
        log_message "error" "无法提取IPv6前缀"
        echo ""
        return 1
    fi
    
    # 检查格式，确保是有效的IPv6前缀
    if echo "$prefix" | grep -q -E '^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){3}$'; then
        # 标准的/64前缀格式
        local result="${prefix}::/64"
        log_message "debug" "提取到IPv6前缀: $result"
        echo "$result"
        return 0
    else
        log_message "error" "无效的IPv6前缀格式: $prefix"
        echo ""
        return 1
    fi
}

# 获取LAN接口的IPv6 /64前缀
get_lan_ipv6_prefix() {
    log_message "debug" "开始获取LAN接口的IPv6 /64前缀"
    
    # 尝试从br-lan接口获取全局IPv6地址
    local lan_ipv6_raw=$(ip -6 addr show dev br-lan 2>/dev/null | \
                    grep 'inet6.*global' | \
                    grep -v 'deprecated' | \
                    head -1)
    
    if [ -z "$lan_ipv6_raw" ]; then
        log_message "debug" "br-lan接口没有全局IPv6地址，尝试其他接口"
        # 尝试其他LAN相关接口
        for iface in lan eth0; do
            lan_ipv6_raw=$(ip -6 addr show dev "$iface" 2>/dev/null | \
                          grep 'inet6.*global' | \
                          grep -v 'deprecated' | \
                          head -1)
            if [ -n "$lan_ipv6_raw" ]; then
                break
            fi
        done
    fi
    
    if [ -z "$lan_ipv6_raw" ]; then
        log_message "error" "未找到LAN接口的全局IPv6地址"
        return 1
    fi
    
    # 提取完整的IPv6地址（包含/64后缀）
    local lan_ipv6_full=$(echo "$lan_ipv6_raw" | awk '{print $2}')
    
    if [ -z "$lan_ipv6_full" ]; then
        log_message "error" "无法提取IPv6地址"
        return 1
    fi
    
    log_message "debug" "找到LAN IPv6地址: $lan_ipv6_full"
    
    # 检查是否为/64地址
    if echo "$lan_ipv6_full" | grep -q '/64$'; then
        # 已经是/64格式，直接返回
        log_message "info" "LAN IPv6 /64前缀: $lan_ipv6_full"
        echo "$lan_ipv6_full"
        return 0
    else
        # 提取地址部分，不包括后缀
        local lan_ipv6=$(echo "$lan_ipv6_full" | cut -d'/' -f1)
        
        # 验证是否为公网地址（2xxx:: 或 3xxx:: 开头）
        if echo "$lan_ipv6" | grep -q -E '^2[0-9a-f][0-9a-f][0-9a-f]:' || \
           echo "$lan_ipv6" | grep -q -E '^3[0-9a-f][0-9a-f][0-9a-f]:'; then
            log_message "info" "找到公网LAN IPv6地址: $lan_ipv6"
            
            # 获取/64前缀
            local prefix_64=$(get_ipv6_prefix_64 "$lan_ipv6")
            if [ -n "$prefix_64" ]; then
                log_message "info" "LAN IPv6 /64前缀: $prefix_64"
                echo "$prefix_64"
                return 0
            else
                log_message "error" "无法提取LAN IPv6 /64前缀"
                return 1
            fi
        else
            log_message "debug" "LAN IPv6地址不是公网地址: $lan_ipv6"
            return 1
        fi
    fi
}

# 查找防火墙规则（修复版，支持匿名规则）
find_firewall_rule() {
    local rule_name="$1"
    
    log_message "debug" "查找防火墙规则: $rule_name"
    
    # 方法1：直接遍历所有规则（支持匿名规则）
    uci -q show firewall | grep "=rule$" | while read rule_line; do
        local section=$(echo "$rule_line" | cut -d. -f2)
        
        # 获取规则名称
        local name=$(uci -q get firewall.$section.name 2>/dev/null)
        
        if [ "$name" = "$rule_name" ]; then
            log_message "debug" "找到防火墙规则段: $section"
            echo "$section"
            return 0
        fi
    done
    
    # 如果没有找到，尝试另一种方法
    # 获取所有规则配置，然后查找
    local all_rules=$(uci -q show firewall | grep -E "\.name='" | grep "$rule_name")
    if [ -n "$all_rules" ]; then
        local section=$(echo "$all_rules" | head -1 | cut -d. -f2)
        log_message "debug" "找到防火墙规则段(备用方法): $section"
        echo "$section"
        return 0
    fi
    
    log_message "error" "未找到防火墙规则: $rule_name"
    echo ""
    return 1
}

# 更新防火墙规则
update_firewall_rule() {
    local new_prefix="$1"
    
    # 检查是否启用了防火墙自动更新
    local firewall_enabled=$(get_config_value "hotplug_firewall_enabled" "0")
    if [ "$firewall_enabled" != "1" ]; then
        log_message "debug" "防火墙自动更新功能未启用"
        return 0
    fi
    
    # 获取防火墙规则名称
    local firewall_name=$(get_config_value "hotplug_firewall_name" "openvpn_ipv6")
    if [ -z "$firewall_name" ]; then
        log_message "error" "防火墙规则名称未配置"
        return 1
    fi
    
    log_message "info" "开始更新防火墙规则: $firewall_name"
    
    # 查找防火墙规则
    local rule_section=$(find_firewall_rule "$firewall_name")
    
    if [ -z "$rule_section" ]; then
        log_message "error" "未找到防火墙规则: $firewall_name"
        
        # 输出所有规则名，便于调试
        log_message "debug" "所有防火墙规则名称:"
        uci -q show firewall | grep "\.name='" | sed 's/^/  /' >> /tmp/openvpn_hotplug.log 2>&1
        
        return 1
    fi
    
    log_message "info" "找到防火墙规则段: $rule_section"
    
    # 获取当前的dest_ip列表
    local current_dest_ips=""
    local needs_update=1
    
    # 使用uci get获取dest_ip列表
    current_dest_ips=$(uci -q get firewall.$rule_section.dest_ip 2>/dev/null)
    
    if [ -z "$current_dest_ips" ]; then
        log_message "info" "规则 $firewall_name 没有dest_ip配置"
        needs_update=1
    else
        log_message "debug" "当前dest_ip列表:"
        # 遍历dest_ip列表
        for dest_ip in $current_dest_ips; do
            log_message "debug" "  - $dest_ip"
            if [ "$dest_ip" = "$new_prefix" ]; then
                log_message "info" "防火墙规则已经包含目标前缀: $new_prefix"
                needs_update=0
                break
            fi
        done
    fi
    
    # 如果需要更新
    if [ "$needs_update" = "1" ]; then
        log_message "info" "更新防火墙规则，设置dest_ip为: $new_prefix"
        
        # 先删除所有现有的dest_ip（使用uci delete）
        while uci -q delete firewall.$rule_section.dest_ip 2>/dev/null; do
            log_message "debug" "删除现有dest_ip"
        done
        
        # 添加新的dest_ip
        if uci -q add_list firewall.$rule_section.dest_ip="$new_prefix" 2>&1; then
            log_message "debug" "添加新的dest_ip: $new_prefix"
        else
            log_message "error" "添加dest_ip失败"
            return 1
        fi
        
        # 提交更改
        if uci commit firewall 2>&1; then
            log_message "info" "防火墙配置保存成功"
            
            # 重新加载防火墙
            if /etc/init.d/firewall reload >/dev/null 2>&1; then
                log_message "info" "防火墙重新加载成功"
                return 0
            else
                log_message "error" "防火墙重新加载失败"
                return 1
            fi
        else
            log_message "error" "防火墙配置保存失败"
            return 1
        fi
    else
        log_message "info" "防火墙规则无需更新"
        return 0
    fi
}

# 获取公网IPv6地址（智能判断版）
get_public_ipv6() {
    local target_interface="$1"
    
    log_message "debug" "开始获取接口 $target_interface 的IPv6地址"
    
    # 根据目标接口获取实际的网络接口
    local actual_interface=""
    case "$target_interface" in
        lan6|lan)
            actual_interface="br-lan"
            ;;
        wan6)
            actual_interface="wan"
            ;;
        wan)
            actual_interface="pppoe-wan"
            ;;
        *)
            actual_interface="$target_interface"
            ;;
    esac
    
    log_message "debug" "实际检查的接口: $actual_interface (原接口: $target_interface)"
    
    # 检查接口是否存在
    if ! ip link show "$actual_interface" >/dev/null 2>&1; then
        log_message "error" "接口 $actual_interface 不存在"
        echo ""
        return 1
    fi
    
    # 判断是否是LAN接口
    local is_lan_interface=0
    case "$target_interface" in
        lan|lan6|br-lan)
            is_lan_interface=1
            log_message "debug" "检测到LAN接口模式"
            ;;
        *)
            is_lan_interface=0
            log_message "debug" "检测到WAN接口模式"
            ;;
    esac
    
    # 获取该接口的所有IPv6地址
    local ipv6_addresses=$(ip -6 addr show dev "$actual_interface" 2>/dev/null | \
                          grep 'inet6.*global' | \
                          grep -v 'deprecated' | \
                          awk '{print $2}')
    
    if [ -z "$ipv6_addresses" ]; then
        log_message "debug" "接口 $actual_interface 没有全局IPv6地址"
        echo ""
        return 1
    fi
    
    log_message "debug" "找到的IPv6地址:"
    log_message "debug" "$ipv6_addresses"
    
    # 使用for循环代替while read，避免重定向问题
    local ipv6_addr=""
    for ipv6_with_prefix in $(echo "$ipv6_addresses"); do
        local ipv6=$(echo "$ipv6_with_prefix" | cut -d'/' -f1)
        local prefix_len=$(echo "$ipv6_with_prefix" | cut -d'/' -f2)
        
        if [ "$is_lan_interface" = "1" ]; then
            # ==========================================
            # LAN接口模式（旁路由）：优先选择公网地址
            # ==========================================
            # 检查是否是公网地址 (2xxx:: 或 3xxx:: 开头)
            if echo "$ipv6" | grep -q -E '^2[0-9a-f][0-9a-f][0-9a-f]:' || \
               echo "$ipv6" | grep -q -E '^3[0-9a-f][0-9a-f][0-9a-f]:'; then
                
                # 排除/128地址和ULA地址
                if [ "$prefix_len" != "128" ] && \
                   ! echo "$ipv6" | grep -q '^fd' && \
                   ! echo "$ipv6" | grep -q '^fc'; then
                    log_message "info" "LAN模式：使用公网IPv6地址: $ipv6"
                    ipv6_addr="$ipv6"
                    break
                else
                    log_message "debug" "LAN模式：跳过地址 (前缀: /$prefix_len 或 ULA): $ipv6"
                fi
            fi
        else
            # ==========================================
            # WAN接口模式（主路由）：必须使用公网地址
            # ==========================================
            # WAN接口模式：只接受以2或3开头的公网地址
            if echo "$ipv6" | grep -q -E '^2[0-9a-f][0-9a-f][0-9a-f]:' || \
               echo "$ipv6" | grep -q -E '^3[0-9a-f][0-9a-f][0-9a-f]:'; then
                
                # 排除/128地址和ULA地址
                if [ "$prefix_len" != "128" ] && \
                   ! echo "$ipv6" | grep -q '^fd' && \
                   ! echo "$ipv6" | grep -q '^fc'; then
                    log_message "info" "WAN模式：找到公网IPv6地址: $ipv6"
                    ipv6_addr="$ipv6"
                    break
                else
                    log_message "debug" "WAN模式：跳过地址 (前缀: /$prefix_len 或 ULA): $ipv6"
                fi
            fi
        fi
    done
    
    # 如果LAN模式没有找到合适的公网地址，使用第一个非ULA地址
    if [ -z "$ipv6_addr" ] && [ "$is_lan_interface" = "1" ]; then
        for ipv6_with_prefix in $(echo "$ipv6_addresses"); do
            local ipv6=$(echo "$ipv6_with_prefix" | cut -d'/' -f1)
            local prefix_len=$(echo "$ipv6_with_prefix" | cut -d'/' -f2)
            
            # 排除ULA地址和/128地址
            if [ "$prefix_len" != "128" ] && \
               ! echo "$ipv6" | grep -q '^fd' && \
               ! echo "$ipv6" | grep -q '^fc'; then
                ipv6_addr="$ipv6"
                log_message "info" "LAN模式：使用非ULA IPv6地址: $ipv6_addr"
                break
            fi
        done
    fi
    
    # 最后尝试：如果还是没找到，使用第一个地址
    if [ -z "$ipv6_addr" ] && [ "$is_lan_interface" = "1" ]; then
        ipv6_addr=$(echo "$ipv6_addresses" | head -1 | cut -d'/' -f1)
        log_message "warning" "LAN模式：使用第一个IPv6地址: $ipv6_addr"
    fi
    
    if [ -n "$ipv6_addr" ]; then
        echo "$ipv6_addr"
        return 0
    else
        log_message "error" "未找到可用的IPv6地址"
        echo ""
        return 1
    fi
}

# 检查OpenVPN配置
check_openvpn_config() {
    log_message "debug" "开始检查OpenVPN配置"
    
    # 检查实例是否存在
    if ! uci -q get openvpn.$OPENVPN_INSTANCE >/dev/null 2>&1; then
        log_message "error" "OpenVPN实例不存在: $OPENVPN_INSTANCE"
        return 1
    fi
    
    # 检查是否启用了IPv6（是否有local选项）
    local has_local=$(uci -q get openvpn.$OPENVPN_INSTANCE.local)
    if [ -n "$has_local" ]; then
        log_message "info" "OpenVPN已配置IPv6地址: $has_local"
        echo "$has_local"
        return 0
    else
        log_message "info" "OpenVPN未启用IPv6配置"
        echo ""
        return 0
    fi
}

# 主函数开始
main() {
    local script_start_time=$(date +%s)
    
    # 检查进程锁
    check_process_lock
    
    # 设置退出时清理
    trap cleanup EXIT
    
    log_message "info" "=== Hotplug脚本启动: ACTION=$1, INTERFACE=$2 ==="
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # =======================================================
    # 修改：添加智能接口选择逻辑
    # =======================================================
    # 读取配置
    MONITOR_INTERFACE=$(get_config_value "hotplug_interface" "")
    IPV6_INTERFACE_CFG=$(get_config_value "hotplug_ipv6_interface" "auto")
    TEMP_DIR=$(get_config_value "temp_dir" "/tmp/openvpn-admin")
    
    # 智能选择IPv6接口
    IPV6_INTERFACE=""
    if [ -z "$IPV6_INTERFACE_CFG" ] || [ "$IPV6_INTERFACE_CFG" = "auto" ] || [ "$IPV6_INTERFACE_CFG" = "same" ]; then
        # 自动模式：使用监控接口
        IPV6_INTERFACE="$MONITOR_INTERFACE"
        log_message "info" "IPv6接口选择: 自动模式，使用监控接口: $IPV6_INTERFACE"
    else
        # 手动指定接口
        IPV6_INTERFACE="$IPV6_INTERFACE_CFG"
        log_message "info" "IPv6接口选择: 手动指定接口: $IPV6_INTERFACE"
    fi
    
    log_message "debug" "配置详情 - 监控接口: $MONITOR_INTERFACE, IPv6接口: $IPV6_INTERFACE, 配置值: $IPV6_INTERFACE_CFG"
    # =======================================================
    # 修改结束
    # =======================================================
    
    # 确保临时目录存在
    mkdir -p "$TEMP_DIR" 2>/dev/null
    
    # 检查是否是我们监控的接口
    if [ -z "$MONITOR_INTERFACE" ]; then
        log_message "error" "未配置监控接口"
        exit 1
    fi
    
    ACTION="$1"
    INTERFACE="$2"
    
    log_message "info" "监控接口: $MONITOR_INTERFACE, 当前接口: $INTERFACE, 动作: $ACTION"
    
    # 检查是否是我们要处理的接口
    if [ "$INTERFACE" != "$MONITOR_INTERFACE" ]; then
        # 简化接口映射检查
        case "$MONITOR_INTERFACE" in
            lan6|lan)
                [ "$INTERFACE" = "br-lan" ] || exit 0
                log_message "info" "处理逻辑接口 $MONITOR_INTERFACE (对应物理接口 br-lan)"
                ;;
            wan6)
                [ "$INTERFACE" = "wan" ] || exit 0
                ;;
            wan)
                [ "$INTERFACE" = "pppoe-wan" -o "$INTERFACE" = "wan" ] || exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    fi
    
    # 只有ifup和ifupdate事件才处理
    if [ "$ACTION" != "ifup" ] && [ "$ACTION" != "ifupdate" ]; then
        log_message "debug" "忽略非up/update事件: $ACTION"
        exit 0
    fi
    
    log_message "info" "开始处理接口事件: $ACTION $INTERFACE (逻辑接口: $MONITOR_INTERFACE)"
    
    #等待60秒确保IPv6获取完成  
    log_message "info" "等待网络稳定........... 等待60秒确保IPv6获取完成 ➡➡➡➡➡➡➡➡➡➡➡➡➡>️"
        sleep 10
    log_message "info" "还需等待 50秒 确保IPv6获取完成 ➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡>️"
        sleep 10
    log_message "info" "还需等待 40秒 确保IPv6获取完成 ➡➡➡➡➡➡➡➡➡➡➡➡➡➡➡>"
        sleep 10
    log_message "info" "还需等待 30秒 确保IPv6获取完成 ➡➡➡➡➡➡➡➡➡➡>"
        sleep 10
    log_message "info" "还需等待 20秒 确保IPv6获取完成 ➡➡➡➡➡>"
        sleep 10
    log_message "info" "还需等待 10秒 确保IPv6获取完成 ➡>"
        sleep 10                                    
    log_message "debug" "网络稳定等待完成"
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # =======================================================
    # 修改：使用智能选择的接口获取IPv6地址
    # =======================================================
    # 获取当前公网IPv6地址
    log_message "debug" "开始获取IPv6地址 (使用接口: $IPV6_INTERFACE)"
    current_ipv6=$(get_public_ipv6 "$IPV6_INTERFACE")
    log_message "debug" "获取IPv6地址完成，结果: $current_ipv6"
    # =======================================================
    # 修改结束
    # =======================================================
    
    if [ -z "$current_ipv6" ]; then
        log_message "error" "无法获取IPv6地址，退出处理"
        exit 1
    fi
    
    log_message "info" "当前IPv6地址: $current_ipv6"
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # 检查OpenVPN配置
    log_message "debug" "调用check_openvpn_config"
    configured_ipv6=$(check_openvpn_config)
    check_result=$?
    log_message "debug" "检查结果: $check_result, 配置地址: $configured_ipv6"
    
    if [ $check_result -ne 0 ]; then
        log_message "error" "OpenVPN配置检查失败"
        exit 1
    fi
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # 判断是否需要更新
    log_message "debug" "判断是否需要更新配置"
    
    if [ -z "$configured_ipv6" ]; then
        # OpenVPN没有配置IPv6，添加配置
        log_message "info" "OpenVPN未配置IPv6，添加IPv6配置: $current_ipv6"
        
        # 设置新的IPv6地址
        log_message "info" "执行: uci set openvpn.$OPENVPN_INSTANCE.local='$current_ipv6'"
        if ! uci set openvpn.$OPENVPN_INSTANCE.local="$current_ipv6" 2>&1; then
            log_message "error" "设置IPv6地址失败"
            exit 1
        fi
        
    else
        # 检查地址是否相同
        if [ "$configured_ipv6" = "$current_ipv6" ]; then
            log_message "info" "IPv6地址未变化，无需更新"
            exit 0
        else
            log_message "info" "地址不同，需要更新: $configured_ipv6 -> $current_ipv6"
            
            # 设置新的IPv6地址
            log_message "info" "执行: uci set openvpn.$OPENVPN_INSTANCE.local='$current_ipv6'"
            if ! uci set openvpn.$OPENVPN_INSTANCE.local="$current_ipv6" 2>&1; then
                log_message "error" "设置IPv6地址失败"
                exit 1
            fi
        fi
    fi
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # 提交更改
    log_message "info" "执行: uci commit openvpn"
    if ! uci commit openvpn 2>&1; then
        log_message "error" "配置提交失败"
        exit 1
    fi
    
    log_message "info" "配置保存成功"
    
    # 延迟验证，避免uci缓存问题
    log_message "debug" "等待1秒让uci配置生效..."
    sleep 1
    
    # 简化验证
    local verify_config=$(uci -q get openvpn.$OPENVPN_INSTANCE.local 2>/dev/null || echo "")
    if [ "$verify_config" = "$current_ipv6" ]; then
        log_message "info" "配置验证成功"
    else
        if [ -n "$verify_config" ]; then
            log_message "warning" "配置验证不匹配，但配置已更新为: $verify_config"
        else
            log_message "error" "配置未保存，但继续尝试重启服务"
        fi
    fi
    
    # 检查超时
    check_timeout "$script_start_time"
    
    # 异步重启OpenVPN服务（避免阻塞hotplug进程）
    log_message "info" "异步重启OpenVPN服务..."
    (
        # 等待一小段时间确保配置完全生效
        sleep 2
        
        # 尝试优雅重启
        if /etc/init.d/openvpn restart >/dev/null 2>&1; then
            log_message "info" "OpenVPN服务重启成功"
        else
            # 如果优雅重启失败，尝试强制重启
            log_message "warning" "优雅重启失败，尝试强制重启..."
            /etc/init.d/openvpn stop >/dev/null 2>&1
            sleep 1
            /etc/init.d/openvpn start >/dev/null 2>&1
            log_message "info" "OpenVPN服务强制重启完成"
        fi
    ) &
    
    # 检查超时
    check_timeout "$script_start_time"
    
    log_message "info" "=== OpenVPN配置更新完成 ==="
    
    # ============================================================
    # 新增功能：防火墙规则自动更新（仅在原脚本任务完成后执行）
    # ============================================================
    
    # 检查防火墙自动更新是否启用
    local firewall_enabled=$(get_config_value "hotplug_firewall_enabled" "0")
    if [ "$firewall_enabled" != "1" ]; then
        log_message "debug" "防火墙自动更新功能未启用，跳过防火墙更新"
        log_message "info" "=== Hotplug脚本执行完成 ==="
        exit 0
    fi
    
    log_message "info" "开始执行防火墙规则自动更新..."
    
    # 获取LAN接口的IPv6 /64前缀
    local lan_ipv6_prefix=$(get_lan_ipv6_prefix)
    if [ -z "$lan_ipv6_prefix" ]; then
        log_message "error" "无法获取LAN IPv6 /64前缀，跳过防火墙更新"
        log_message "info" "=== Hotplug脚本执行完成 ==="
        exit 0
    fi
    
    log_message "info" "LAN IPv6 /64前缀: $lan_ipv6_prefix"
    
    # 更新防火墙规则
    if update_firewall_rule "$lan_ipv6_prefix"; then
        log_message "info" "防火墙规则更新成功"
    else
        log_message "error" "防火墙规则更新失败"
    fi
    
    # 检查超时
    check_timeout "$script_start_time"
    
    log_message "info" "=== Hotplug脚本执行完成 ==="
}

# 运行主函数
main "$@"
exit 0
]]
    
    local fd = io.open(script_path, "w")
    if fd then
        fd:write(script_content)
        fd:close()
        sys.exec("chmod +x " .. script_path .. " 2>/dev/null")
        
        -- 创建hotplug配置
        create_hotplug_config(config)
        
        -- 记录日志
        nixio.syslog("info", "OpenVPN Hotplug脚本已更新: " .. script_path)
        
        return true
    end
    return false
end

-- 创建hotplug配置文件
function create_hotplug_config(config)
    local hotplug_dir = "/etc/hotplug.d/iface"
    local hotplug_script = config.hotplug_script_path or "/etc/openvpn/openvpn_hotplug.sh"
    local monitor_interface = config.hotplug_interface or ""
    
    -- 确保hotplug目录存在
    sys.exec("mkdir -p " .. hotplug_dir .. " 2>/dev/null")
    
    -- 解析接口名，处理逻辑接口
    local actual_interface = monitor_interface
    if monitor_interface == "lan6" or monitor_interface == "lan" then
        -- 对于lan6/lan逻辑接口，也要监控br-lan的物理接口变化
        actual_interface = "br-lan"
    end
    
    local config_content = [[
#!/bin/sh

# OpenVPN Hotplug配置
# 自动监控网络接口变化

[ "$ACTION" = "ifup" -o "$ACTION" = "ifdown" -o "$ACTION" = "ifupdate" ] || exit 0

# 监控的接口（支持逻辑接口和物理接口）
INTERFACE_TO_MONITOR="]] .. monitor_interface .. [["
PHYSICAL_INTERFACE="]] .. (actual_interface or "") .. [["

# 处理逻辑接口：lan6/lan 对应 br-lan
if [ "$INTERFACE_TO_MONITOR" = "lan6" -o "$INTERFACE_TO_MONITOR" = "lan" ]; then
    # 当br-lan物理接口变化时，也触发lan6/lan的逻辑处理
    if [ "$INTERFACE" = "br-lan" ]; then
        # 设置逻辑接口名，传递给脚本
        ]] .. hotplug_script .. [[ "$ACTION" "$INTERFACE_TO_MONITOR" &
        exit 0
    fi
fi

# 处理逻辑接口：wan6 对应 wan
if [ "$INTERFACE_TO_MONITOR" = "wan6" ]; then
    if [ "$INTERFACE" = "wan" ]; then
        ]] .. hotplug_script .. [[ "$ACTION" "$INTERFACE_TO_MONITOR" &
        exit 0
    fi
fi

# 处理逻辑接口：wan 对应 pppoe-wan
if [ "$INTERFACE_TO_MONITOR" = "wan" ]; then
    if [ "$INTERFACE" = "pppoe-wan" ]; then
        ]] .. hotplug_script .. [[ "$ACTION" "$INTERFACE_TO_MONITOR" &
        exit 0
    fi
fi

# 直接匹配监控的接口
if [ "$INTERFACE" = "$INTERFACE_TO_MONITOR" ]; then
    # 执行OpenVPN hotplug脚本
    ]] .. hotplug_script .. [[ "$ACTION" "$INTERFACE" &
    exit 0
fi

# 如果没有匹配，检查是否是物理接口对应的逻辑接口
if [ -n "$PHYSICAL_INTERFACE" -a "$INTERFACE" = "$PHYSICAL_INTERFACE" ]; then
    # 物理接口变化时，也触发逻辑接口处理
    ]] .. hotplug_script .. [[ "$ACTION" "$INTERFACE_TO_MONITOR" &
    exit 0
fi

exit 0
]]
    
    local config_file = hotplug_dir .. "/99-openvpn-admin"
    local fd = io.open(config_file, "w")
    if fd then
        fd:write(config_content)
        fd:close()
        sys.exec("chmod +x " .. config_file .. " 2>/dev/null")
        
        -- 记录配置
        nixio.syslog("info", "OpenVPN Hotplug配置已更新，监控接口: " .. monitor_interface .. 
                    "，物理接口: " .. actual_interface)
        return true
    end
    return false
end

-- 新增：比较并更新IPv6地址
function action_compare_and_update_ipv6()
    local result = {
        success = false,
        need_update = false,
        configured_ipv6 = "",
        message = ""
    }
    
    -- 获取参数
    local ipv6_address = http.formvalue("ipv6_address")
    local instance = http.formvalue("instance")
    
    if not ipv6_address or ipv6_address == "" then
        result.message = "IPv6地址不能为空"
        http.write_json(result)
        return
    end
    
    if not instance or instance == "" then
        instance = get_openvpn_instance()
    end
    
    -- 检查实例是否存在
    local exists = uci:get("openvpn", instance)
    if not exists then
        result.message = "OpenVPN实例不存在: " .. instance
        http.write_json(result)
        return
    end
    
    -- 获取当前配置的IPv6地址
    local configured_ipv6 = uci:get("openvpn", instance, "local") or ""
    result.configured_ipv6 = configured_ipv6
    
    -- 比较地址
    if configured_ipv6 == ipv6_address then
        result.success = true
        result.need_update = false
        result.message = "IPv6地址一致，无需更新"
    else
        -- 需要更新
        local ok, err = pcall(function()
            uci:set("openvpn", instance, "local", ipv6_address)
            uci:save("openvpn")
            uci:commit("openvpn")
        end)
        
        if ok then
            result.success = true
            result.need_update = true
            result.message = "IPv6地址已更新"
            nixio.syslog("info", string.format("OpenVPN IPv6地址手动更新: %s -> %s", 
                         configured_ipv6 or "未配置", ipv6_address))
        else
            result.success = false
            result.message = "更新失败: " .. tostring(err)
        end
    end
    
    http.write_json(result)
end

-- 新增：重启OpenVPN服务
function action_restart_openvpn()
    local result = {
        success = false,
        message = ""
    }
    
    -- 重启OpenVPN服务
    local ret = sys.call("/etc/init.d/openvpn restart >/dev/null 2>&1")
    
    if ret == 0 then
        result.success = true
        result.message = "OpenVPN服务重启成功"
        nixio.syslog("info", "OpenVPN服务手动重启")
    else
        result.message = "OpenVPN服务重启失败"
        nixio.syslog("err", "OpenVPN服务手动重启失败")
    end
    
    http.write_json(result)
end

-- 检查防火墙规则是否存在
function check_firewall_rule()
    local rule_exists = false
    local rule_section = nil
    
    -- 遍历防火墙规则
    uci:foreach("firewall", "rule",
        function(section)
            if section.name == "openvpn" then
                rule_exists = true
                rule_section = section[".name"]
                return false  -- 停止遍历
            end
        end
    )
    
    return rule_exists, rule_section
end

-- 更新防火墙端口规则
function update_firewall_port(old_port, new_port)
    local result = false
    
    -- 查找现有的OpenVPN防火墙规则
    local rule_exists, rule_section = check_firewall_rule()
    
    if rule_exists and rule_section then
        -- 更新现有规则的端口
        local ok, err = pcall(function()
            uci:set("firewall", rule_section, "dest_port", new_port)
            uci:save("firewall")
            uci:commit("firewall")
        end)
        
        if ok then
            -- 重新加载防火墙
            local reload_result = sys.call("/etc/init.d/firewall reload >/dev/null 2>&1")
            if reload_result == 0 then
                nixio.syslog("info", string.format("OpenVPN防火墙规则已更新，端口从 %s 改为 %s", old_port, new_port))
                result = true
            else
                nixio.syslog("err", "防火墙重新加载失败")
            end
        else
            nixio.syslog("err", "更新防火墙规则失败: " .. tostring(err))
        end
    else
        -- 规则不存在，创建新规则
        result = add_firewall_port(new_port)
    end
    
    return result
end

-- 添加防火墙端口规则
function add_firewall_port(port)
    local result = false
    
    -- 创建新的防火墙规则
    local section_name = uci:add("firewall", "rule")
    
    if section_name then
        local ok, err = pcall(function()
            -- 设置规则参数
            uci:set("firewall", section_name, "name", "openvpn")
            uci:set("firewall", section_name, "src", "wan")
            uci:set("firewall", section_name, "proto", "tcp udp")  -- 同时允许TCP和UDP
            uci:set("firewall", section_name, "dest_port", port)
            uci:set("firewall", section_name, "target", "ACCEPT")
            
            -- 保存并提交
            uci:save("firewall")
            uci:commit("firewall")
        end)
        
        if ok then
            -- 重新加载防火墙
            local reload_result = sys.call("/etc/init.d/firewall reload >/dev/null 2>&1")
            if reload_result == 0 then
                nixio.syslog("info", string.format("已添加OpenVPN防火墙规则，端口: %s", port))
                result = true
            else
                nixio.syslog("err", "防火墙重新加载失败")
                -- 回滚：删除刚创建的规则
                uci:delete("firewall", section_name)
                uci:save("firewall")
                uci:commit("firewall")
            end
        else
            nixio.syslog("err", "添加防火墙规则失败: " .. tostring(err))
            -- 回滚
            uci:delete("firewall", section_name)
            uci:save("firewall")
        end
    else
        nixio.syslog("err", "无法创建防火墙规则section")
    end
    
    return result
end

-- 检查旁路由IPv6防火墙规则是否存在
function check_ipv6_firewall_rule()
    local result = {
        success = false,
        exists = false,
        message = "",
        rule_name = "",
        rule_info = {}
    }
    
    -- 获取规则名称（从管理配置中）
    local config = get_admin_config()
    local rule_name = config.hotplug_firewall_name or "openvpn_ipv6"
    result.rule_name = rule_name
    
    -- 遍历防火墙规则，查找匹配的规则
    local rule_exists = false
    local rule_section = nil
    
    uci:foreach("firewall", "rule",
        function(section)
            if section.name == rule_name then
                rule_exists = true
                rule_section = section[".name"]
                
                -- 收集规则信息
                result.rule_info = {
                    section = rule_section,
                    src = section.src or "",
                    dest = section.dest or "",
                    proto = section.proto or "",
                    dest_port = section.dest_port or "",
                    target = section.target or "",
                    src_ip = section.src_ip or "",
                    dest_ip = section.dest_ip or "",
                    enabled = section.enabled or "1"
                }
                
                return false  -- 停止遍历
            end
        end
    )
    
    result.exists = rule_exists
    result.success = true
    result.message = rule_exists and "规则存在" or "规则不存在"
    
    return result
end

-- 创建或更新旁路由IPv6防火墙规则
function update_ipv6_firewall_rule(dest_ip_prefix)
    local result = {
        success = false,
        message = "",
        created = false,
        rule_name = ""
    }
    
    -- 获取配置
    local config = get_admin_config()
    local rule_name = config.hotplug_firewall_name or "openvpn_ipv6"
    local enabled = config.hotplug_firewall_enabled or false
    result.rule_name = rule_name
    
    -- 如果未启用防火墙自动更新，直接返回
    if not enabled then
        result.success = true
        result.message = "防火墙自动更新未启用"
        return result
    end
    
    -- 如果没有目标IP前缀，使用默认值
    if not dest_ip_prefix or dest_ip_prefix == "" then
        dest_ip_prefix = "::1/128"  -- 默认使用IPv6环回地址
    end
    
    -- 检查规则是否存在
    local rule_exists, rule_section = false, nil
    uci:foreach("firewall", "rule",
        function(section)
            if section.name == rule_name then
                rule_exists = true
                rule_section = section[".name"]
                return false
            end
        end
    )
    
    if rule_exists and rule_section then
        -- 更新现有规则
        local ok, err = pcall(function()
            -- 更新dest_ip（清除旧值后添加新值）
            uci:delete("firewall", rule_section, "dest_ip")
            uci:set_list("firewall", rule_section, "dest_ip", {dest_ip_prefix})
            
            -- 确保其他参数正确（按照要求设置默认值）
            uci:set("firewall", rule_section, "src", "wan")
            uci:set("firewall", rule_section, "dest", "lan")
            uci:set("firewall", rule_section, "name", rule_name)
            uci:set("firewall", rule_section, "proto", "udp tcp")  -- 同时允许TCP和UDP
            uci:set("firewall", rule_section, "dest_port", "1194")
            uci:set("firewall", rule_section, "target", "ACCEPT")
            uci:set_list("firewall", rule_section, "src_ip", {"::/0"})
            uci:set("firewall", rule_section, "enabled", "1")
            
            uci:save("firewall")
            uci:commit("firewall")
        end)
        
        if ok then
            result.success = true
            result.created = false
            result.message = "旁路由IPv6防火墙规则已更新"
        else
            result.message = "更新防火墙规则失败: " .. tostring(err)
        end
    else
        -- 创建新规则
        local section_name = uci:add("firewall", "rule")
        
        if section_name then
            local ok, err = pcall(function()
                -- 设置规则参数（按照要求）
                uci:set("firewall", section_name, "src", "wan")
                uci:set("firewall", section_name, "dest", "lan")
                uci:set("firewall", section_name, "name", rule_name)
                uci:set("firewall", section_name, "proto", "udp tcp")  -- 同时允许TCP和UDP
                uci:set("firewall", section_name, "dest_port", "1194")
                uci:set("firewall", section_name, "target", "ACCEPT")
                uci:set_list("firewall", section_name, "src_ip", {"::/0"})
                uci:set_list("firewall", section_name, "dest_ip", {dest_ip_prefix})
                uci:set("firewall", section_name, "enabled", "1")
                
                uci:save("firewall")
                uci:commit("firewall")
            end)
            
            if ok then
                result.success = true
                result.created = true
                result.message = "旁路由IPv6防火墙规则已创建"
            else
                result.message = "创建防火墙规则失败: " .. tostring(err)
                -- 回滚
                uci:delete("firewall", section_name)
                uci:save("firewall")
            end
        else
            result.message = "无法创建防火墙规则section"
        end
    end
    
    -- 如果操作成功，重新加载防火墙
    if result.success then
        local reload_result = sys.call("/etc/init.d/firewall reload >/dev/null 2>&1")
        if reload_result == 0 then
            result.message = result.message .. "，防火墙已重新加载"
        else
            result.message = result.message .. "，但防火墙重新加载失败"
        end
    end
    
    return result
end

-- 删除旁路由IPv6防火墙规则
function delete_ipv6_firewall_rule()
    local result = {
        success = false,
        message = ""
    }
    
    -- 获取规则名称
    local config = get_admin_config()
    local rule_name = config.hotplug_firewall_name or "openvpn_ipv6"
    
    -- 查找规则
    local rule_section = nil
    uci:foreach("firewall", "rule",
        function(section)
            if section.name == rule_name then
                rule_section = section[".name"]
                return false
            end
        end
    )
    
    if rule_section then
        -- 删除规则
        local ok, err = pcall(function()
            uci:delete("firewall", rule_section)
            uci:save("firewall")
            uci:commit("firewall")
        end)
        
        if ok then
            -- 重新加载防火墙
            local reload_result = sys.call("/etc/init.d/firewall reload >/dev/null 2>&1")
            result.success = true
            result.message = "旁路由IPv6防火墙规则已删除"
            if reload_result == 0 then
                result.message = result.message .. "，防火墙已重新加载"
            else
                result.message = result.message .. "，但防火墙重新加载失败"
            end
        else
            result.message = "删除防火墙规则失败: " .. tostring(err)
        end
    else
        result.success = true
        result.message = "规则不存在，无需删除"
    end
    
    return result
end

-- 检查防火墙端口规则（AJAX接口）
function check_firewall_rule_ajax()
    local result = {
        success = false,
        exists = false,
        message = ""
    }
    
    local port = http.formvalue("port")
    local instance = get_openvpn_instance()
    
    if not port then
        -- 如果没有提供端口，从OpenVPN配置中获取
        port = uci:get("openvpn", instance, "port")
    end
    
    if port then
        -- 检查防火墙规则是否存在
        local rule_exists, rule_section = check_firewall_rule()
        
        if rule_exists then
            -- 检查端口是否匹配
            local current_port = uci:get("firewall", rule_section, "dest_port")
            result.exists = (current_port == port)
            result.current_port = current_port
            result.expected_port = port
            result.success = true
            result.message = "防火墙规则检查完成"
        else
            result.exists = false
            result.success = true
            result.message = "防火墙规则不存在"
        end
    else
        result.message = "未指定端口"
    end
    
    http.write_json(result)
end

-- 旁路由IPv6防火墙规则AJAX接口处理函数（新增）
function action_check_ipv6_firewall()
    local result = check_ipv6_firewall_rule()
    http.write_json(result)
end

function action_create_ipv6_firewall()
    local dest_ip = http.formvalue("dest_ip") or "::1/128"
    local result = update_ipv6_firewall_rule(dest_ip)
    http.write_json(result)
end

function action_delete_ipv6_firewall()
    local result = delete_ipv6_firewall_rule()
    http.write_json(result)
end

function index()

    
    -- 主菜单项：作为目录入口，使用alias重定向到状态页面
    entry({"admin", "vpn", "openvpn-admin"}, 
          alias("admin", "vpn", "openvpn-admin", "status"), 
          _("OpenVPN Admin"), 
          60).index = true
    
    -- 状态页面（默认页面）
    entry({"admin", "vpn", "openvpn-admin", "status"}, 
          call("action_status"), 
          _("服务状态"), 
          1)
    
    -- 客户端页面
    entry({"admin", "vpn", "openvpn-admin", "client"}, 
          template("openvpn-admin/client"), 
          _("客户端"), 
          2)
    
    -- 服务端页面
    entry({"admin", "vpn", "openvpn-admin", "server"}, 
          template("openvpn-admin/server"), 
          _("服务端"), 
          3)
    
    -- 日志页面（显示OpenVPN服务器日志）
    entry({"admin", "vpn", "openvpn-admin", "logs"}, 
          call("action_logs"), 
          _("日志"), 
          4)
    
    -- 设置页面（新增）
    entry({"admin", "vpn", "openvpn-admin", "settings"}, 
          call("action_settings"), 
          _("设置"), 
          5)
    
    -- AJAX接口：获取OpenVPN状态
    entry({"admin", "vpn", "openvpn-admin", "get_status"}, 
          call("get_openvpn_status"))
    
    -- AJAX接口：启动OpenVPN服务
    entry({"admin", "vpn", "openvpn-admin", "start_service"}, 
          call("start_openvpn_service"))
    
    -- AJAX接口：停止OpenVPN服务
    entry({"admin", "vpn", "openvpn-admin", "stop_service"}, 
          call("stop_openvpn_service"))
    
    -- AJAX接口：断开客户端连接
    entry({"admin", "vpn", "openvpn-admin", "disconnect_client"}, 
          call("disconnect_client"))
    
    -- AJAX接口：清除OpenVPN日志
    entry({"admin", "vpn", "openvpn-admin", "clear_logs"}, 
          call("clear_openvpn_logs"))
    
    -- AJAX接口：下载OpenVPN日志
    entry({"admin", "vpn", "openvpn-admin", "download_logs"}, 
          call("download_openvpn_logs"))
    
    -- AJAX接口：获取OpenVPN日志
    entry({"admin", "vpn", "openvpn-admin", "get_logs"}, 
          call("get_openvpn_logs"))
    
    -- AJAX接口：获取OpenVPN配置文件内容
    entry({"admin", "vpn", "openvpn-admin", "get_config"}, 
          call("get_openvpn_config"))
    
    -- AJAX接口：下载OpenVPN配置文件
    entry({"admin", "vpn", "openvpn-admin", "download_config"}, 
          call("download_openvpn_config"))
    
    -- AJAX接口：获取配置节详情
    entry({"admin", "vpn", "openvpn-admin", "get_section"}, 
          call("get_config_section"))
    
    -- AJAX接口：保存OpenVPN配置
    entry({"admin", "vpn", "openvpn-admin", "save_config"}, 
          call("save_openvpn_config"))
    
    -- AJAX接口：应用OpenVPN配置（保存并重启服务）
    entry({"admin", "vpn", "openvpn-admin", "apply_config"}, 
          call("apply_openvpn_config"))
    
    -- AJAX接口：获取客户端黑名单（基于CN）
    entry({"admin", "vpn", "openvpn-admin", "get_blacklist_cn"}, 
          call("get_blacklist_cn"))
    
    -- AJAX接口：从黑名单中移除客户端（基于CN）
    entry({"admin", "vpn", "openvpn-admin", "remove_from_blacklist_cn"}, 
          call("remove_from_blacklist_cn"))
    
    -- AJAX接口：添加客户端到黑名单（基于CN）
    entry({"admin", "vpn", "openvpn-admin", "add_to_blacklist"}, 
          call("add_client_to_blacklist"))
    
    -- AJAX接口：查找客户端ID
    entry({"admin", "vpn", "openvpn-admin", "find_client_id"}, 
          call("find_client_id"))
    
    -- AJAX接口：生成客户端配置
    entry({"admin", "vpn", "openvpn-admin", "generate_client_config"}, 
          call("generate_client_config"))
    
    -- AJAX接口：重置所有证书
    entry({"admin", "vpn", "openvpn-admin", "reset_all_certificates"}, 
          call("reset_all_certificates"))
    
    -- AJAX接口：下载客户端配置文件
    entry({"admin", "vpn", "openvpn-admin", "download_client_config"}, 
          call("download_client_config"))
    
    -- AJAX接口：获取管理配置（新增）
    entry({"admin", "vpn", "openvpn-admin", "get_admin_config"}, 
          call("get_admin_config_ajax"))
    
    -- AJAX接口：保存管理配置（新增）
    entry({"admin", "vpn", "openvpn-admin", "save_admin_config"}, 
          call("save_admin_config"))
    
    -- AJAX接口：获取OpenVPN UCI配置（新增）
    entry({"admin", "vpn", "openvpn-admin", "get_uci_config"}, 
          call("get_openvpn_uci_config"))
    
    -- AJAX接口：保存OpenVPN UCI配置（新增）
    entry({"admin", "vpn", "openvpn-admin", "save_uci_config"}, 
          call("save_openvpn_uci_config"))
          
     -- 新增：手动触发Hotplug
     entry({"admin", "vpn", "openvpn-admin", "manual_trigger_hotplug"}, 
           call("action_manual_trigger_hotplug"))

     -- 新增：获取Hotplug日志
     entry({"admin", "vpn", "openvpn-admin", "get_hotplug_log"}, 
           call("action_get_hotplug_log"))     
          
    -- 新增：比较并更新IPv6地址
    entry({"admin", "vpn", "openvpn-admin", "compare_and_update_ipv6"}, 
          call("action_compare_and_update_ipv6"))

    -- 新增：重启OpenVPN服务
    entry({"admin", "vpn", "openvpn-admin", "restart_openvpn"}, 
          call("action_restart_openvpn"))      
    
    -- AJAX接口：检查防火墙规则（新增）- 这是OpenVPN服务的端口规则
    entry({"admin", "vpn", "openvpn-admin", "check_firewall"}, 
          call("check_firewall_rule_ajax"))
          
    -- AJAX接口：检查旁路由IPv6防火墙规则（新增）- 旁路由专用，不影响原有功能
    entry({"admin", "vpn", "openvpn-admin", "check_ipv6_firewall"}, 
          call("action_check_ipv6_firewall"))

    -- AJAX接口：创建旁路由IPv6防火墙规则（新增）
    entry({"admin", "vpn", "openvpn-admin", "create_ipv6_firewall"}, 
          call("action_create_ipv6_firewall"))

    -- AJAX接口：删除旁路由IPv6防火墙规则（新增）
    entry({"admin", "vpn", "openvpn-admin", "delete_ipv6_firewall"}, 
          call("action_delete_ipv6_firewall"))      
          
    -- 新增AJAX接口：获取网络接口列表
    entry({"admin", "vpn", "openvpn-admin", "get_interfaces"}, 
          call("action_get_interfaces"))
    
    -- 新增AJAX接口：获取接口IPv6地址
    entry({"admin", "vpn", "openvpn-admin", "get_interface_ipv6"}, 
          call("action_get_interface_ipv6"))      
          
    -- AJAX接口：检查IPv6脚本是否存在
    entry({"admin", "vpn", "openvpn-admin", "check_ipv6_script"}, 
          call("action_check_ipv6_script"),  -- 修改函数名为action_check_ipv6_script
          nil).leaf = true
	
	-- 新增AJAX接口：运行IPv6脚本
    entry({"admin", "vpn", "openvpn-admin", "run_ipv6_script"}, 
          call("action_run_ipv6_script"), 
          nil).leaf = true
end

-- 获取网络接口列表
-- 完全重写 action_get_interfaces() 函数
function action_get_interfaces()
    local result = {
        success = false,
        interfaces = {},
        message = ""
    }
    
    -- 方法1：从UCI network配置获取所有接口
    local uci = require("luci.model.uci").cursor()
    local all_interfaces = {}
    local seen_interfaces = {}
    
    -- 从/etc/config/network读取所有接口配置
    uci:foreach("network", "interface",
        function(section)
            local ifname = section[".name"]
            local device = section.ifname or section.device
            local proto = section.proto or ""
            local type = section.type or ""
            
            -- 跳过loopback和docker接口
            if ifname and ifname ~= "loopback" and not ifname:match("^docker") then
                if not seen_interfaces[ifname] then
                    seen_interfaces[ifname] = true
                    
                    -- 获取接口的实际状态
                    local status = "down"
                    local actual_device = device
                    
                    -- 对于逻辑接口，尝试获取实际的网络设备
                    if not actual_device or actual_device == "" then
                        -- 尝试从ifname获取
                        actual_device = section.ifname or ""
                    end
                    
                    -- 检查接口状态
                    if actual_device and actual_device ~= "" then
                        -- 可能有多个设备（如 "eth0 eth1" 或 "br-lan"）
                        local first_device = actual_device:match("^([%w%-]+)")
                        if first_device then
                            local status_cmd = "cat /sys/class/net/" .. first_device .. "/operstate 2>/dev/null || echo 'down'"
                            status = util.trim(sys.exec(status_cmd) or "down")
                        end
                    else
                        -- 对于没有明确设备的接口（如lan6），检查是否有IPv6地址
                        local ipv6_check = sys.exec("ip -6 addr show 2>/dev/null | grep -E 'inet6.*global' | grep -v 'deprecated' | wc -l")
                        if tonumber(ipv6_check) and tonumber(ipv6_check) > 0 then
                            status = "up"
                        end
                    end
                    
                    -- 特殊处理常见接口类型
                    local display_name = ifname
                    local desc = ""
                    
                    if proto == "pppoe" then
                        desc = "PPPoE拨号"
                    elseif proto == "dhcp" then
                        desc = "DHCP客户端"
                    elseif proto == "static" then
                        desc = "静态配置"
                    elseif type == "bridge" then
                        desc = "桥接接口"
                    end
                    
                    -- 添加接口信息
                    table.insert(all_interfaces, {
                        name = ifname,
                        device = actual_device or "",
                        proto = proto,
                        type = type,
                        status = status,
                        display = ifname .. " (" .. proto:upper() .. " - " .. status:upper() .. ")",
                        config_name = ifname,
                        description = desc
                    })
                end
            end
        end
    )
    
    -- 方法2：从系统获取所有物理网络接口作为补充
    local cmd = "ip -o link show 2>/dev/null | awk '{print $2}' | sed 's/:$//'"
    local output = sys.exec(cmd)
    
    if output and output ~= "" then
        for ifname in output:gmatch("[^\r\n]+") do
            ifname = util.trim(ifname)
            
            -- 跳过不需要的接口
            if not ifname:match("^lo$") and 
               not ifname:match("^docker") and 
               not ifname:match("^veth") and
               not ifname:match("^ip6tnl") and
               not ifname:match("^tunl") and
               not ifname:match("^sit") and
               not ifname:match("^dummy") and
               not ifname:match("^gre") and
               not ifname:match("^gretap") and
               not ifname:match("^erspan") and
               not ifname:match("^siit") and
               not ifname:match("^teql") then
                
                -- 检查是否已经在UCI接口列表中
                local already_exists = false
                for _, existing_iface in ipairs(all_interfaces) do
                    if existing_iface.name == ifname or 
                       (existing_iface.device and existing_iface.device:find(ifname)) then
                        already_exists = true
                        break
                    end
                end
                
                if not already_exists and not seen_interfaces[ifname] then
                    -- 检查接口状态
                    local status_cmd = "cat /sys/class/net/" .. ifname .. "/operstate 2>/dev/null || echo 'down'"
                    local status = sys.exec(status_cmd)
                    status = util.trim(status or "down")
                    
                    -- 获取接口类型
                    local type_cmd = "cat /sys/class/net/" .. ifname .. "/type 2>/dev/null || echo '0'"
                    local iftype = tonumber(sys.exec(type_cmd)) or 0
                    
                    -- 只添加物理接口
                    if iftype == 1 or iftype == 32 or iftype == 65534 then
                        seen_interfaces[ifname] = true
                        
                        table.insert(all_interfaces, {
                            name = ifname,
                            device = ifname,
                            proto = "unknown",
                            type = "physical",
                            status = status,
                            display = ifname .. " (PHY - " .. status:upper() .. ")",
                            config_name = ifname,
                            description = "物理接口"
                        })
                    end
                end
            end
        end
    end
    
    -- 添加特定的逻辑接口（如果不存在）
    local special_interfaces = {"lan", "lan6", "wan", "wan6"}
    for _, special_iface in ipairs(special_interfaces) do
        if not seen_interfaces[special_iface] then
            -- 检查这个逻辑接口是否在UCI配置中
            local iface_config = uci:get("network", special_iface)
            if iface_config then
                seen_interfaces[special_iface] = true
                
                -- 获取设备信息
                local device = uci:get("network", special_iface, "ifname") or 
                               uci:get("network", special_iface, "device") or ""
                local proto = uci:get("network", special_iface, "proto") or "unknown"
                local type = uci:get("network", special_iface, "type") or "interface"
                
                -- 检查状态
                local status = "down"
                if device and device ~= "" then
                    local first_device = device:match("^([%w%-]+)")
                    if first_device then
                        local status_cmd = "cat /sys/class/net/" .. first_device .. "/operstate 2>/dev/null || echo 'down'"
                        status = util.trim(sys.exec(status_cmd) or "down")
                    end
                else
                    -- 对于lan6等逻辑接口，检查是否有IPv6地址
                    local ipv6_check = sys.exec("ip -6 addr show 2>/dev/null | grep 'inet6.*global' | wc -l")
                    if tonumber(ipv6_check) and tonumber(ipv6_check) > 0 then
                        status = "up"
                    end
                end
                
                table.insert(all_interfaces, {
                    name = special_iface,
                    device = device,
                    proto = proto,
                    type = type,
                    status = status,
                    display = special_iface .. " (" .. proto:upper() .. " - " .. status:upper() .. ")",
                    config_name = special_iface,
                    description = "逻辑接口"
                })
            end
        end
    end
    
    -- 按名称排序
    table.sort(all_interfaces, function(a, b)
        -- 优先显示wan/pppoe接口
        if a.name:match("wan") and not b.name:match("wan") then
            return true
        elseif not a.name:match("wan") and b.name:match("wan") then
            return false
        end
        
        -- 然后显示lan接口
        if a.name:match("lan") and not b.name:match("lan") then
            return true
        elseif not a.name:match("lan") and b.name:match("lan") then
            return false
        end
        
        -- 最后按字母排序
        return a.name < b.name
    end)
    
    result.interfaces = all_interfaces
    result.success = true
    
    http.write_json(result)
end

-- 添加一个辅助函数来检查接口是否存在
function check_interface_exists(interface_name)
    local uci = require("luci.model.uci").cursor()
    
    -- 方法1：检查UCI配置
    local uci_exists = uci:get("network", interface_name)
    if uci_exists then
        return true, "uci"
    end
    
    -- 方法2：检查系统接口
    local sys_check = sys.exec("ip link show " .. interface_name .. " 2>/dev/null | head -1")
    if sys_check and sys_check ~= "" then
        return true, "system"
    end
    
    -- 方法3：检查网络配置文件
    local network_content = sys.exec("cat /etc/config/network 2>/dev/null | grep \"config interface.*'" .. interface_name .. "'\"")
    if network_content and network_content ~= "" then
        return true, "config"
    end
    
    return false, "not_found"
end

-- 获取指定接口的IPv6地址
-- 修改 action_get_interface_ipv6() 函数
function action_get_interface_ipv6()
    local result = {
        success = false,
        ipv6_address = "",
        message = ""
    }
    
    local interface = http.formvalue("interface")
    
    if not interface or interface == "" then
        result.message = "未指定网络接口"
        http.write_json(result)
        return
    end
    
    -- 获取UCI cursor
    local uci = require("luci.model.uci").cursor()
    
    -- 获取接口的实际设备
    local actual_device = ""
    local iface_config = uci:get("network", interface)
    
    if iface_config then
        -- 从UCI配置获取设备名
        actual_device = uci:get("network", interface, "ifname") or 
                        uci:get("network", interface, "device") or ""
    else
        -- 如果UCI中没有配置，直接使用接口名
        actual_device = interface
    end
    
    -- 处理逻辑接口的特殊情况
    local interface_aliases = {
        ["lan"] = "br-lan",
        ["lan6"] = "br-lan",
        ["wan6"] = "wan",
        ["wan"] = "pppoe-wan"
    }
    
    -- 获取IPv6地址的函数
    local function get_ipv6_for_device(dev_name)
        if not dev_name or dev_name == "" then
            return nil
        end
        
        -- 设备名可能包含多个设备（如 "eth0 eth1"），取第一个
        local first_device = dev_name:match("^([%w%-]+)")
        if not first_device then
            return nil
        end
        
        -- 获取该设备的所有IPv6地址
        local cmd = "ip -6 addr show dev " .. first_device .. " 2>/dev/null | grep 'inet6.*global' | grep -v 'deprecated'"
        local ipv6_output = sys.exec(cmd)
        
        if ipv6_output and ipv6_output ~= "" then
            -- 收集所有公网IPv6地址
            local addresses = {}
            for line in ipv6_output:gmatch("[^\r\n]+") do
                local ipv6_address = line:match("inet6%s+([%x:]+)/")
                if ipv6_address then
                    -- 检查是否是公网地址（2xxx:: 或 3xxx:: 开头）
                    if ipv6_address:match("^2[0-9a-f][0-9a-f][0-9a-f]:") or 
                       ipv6_address:match("^3[0-9a-f][0-9a-f][0-9a-f]:") then
                        table.insert(addresses, ipv6_address)
                    end
                end
            end
            
            -- 返回第一个找到的公网地址
            if #addresses > 0 then
                return addresses[1]
            end
        end
        
        return nil
    end
    
    -- 尝试从实际设备获取IPv6地址
    local ipv6_address = get_ipv6_for_device(actual_device)
    
    -- 如果从实际设备获取失败，尝试从接口别名获取
    if not ipv6_address and interface_aliases[interface] then
        local alias_device = interface_aliases[interface]
        
        -- 检查别名设备是否存在
        local check_cmd = "ip link show " .. alias_device .. " 2>/dev/null"
        local alias_exists = sys.exec(check_cmd) and sys.exec(check_cmd) ~= ""
        
        if alias_exists then
            ipv6_address = get_ipv6_for_device(alias_device)
            if ipv6_address then
                result.message = "通过关联接口 " .. alias_device .. " 获取"
            end
        end
    end
    
    -- 最后尝试：对于lan6等逻辑接口，直接扫描所有接口的IPv6地址
    if not ipv6_address and (interface == "lan6" or interface == "lan") then
        -- 获取所有接口的第一个公网IPv6地址
        local cmd = "ip -6 addr show 2>/dev/null | grep 'inet6.*global' | grep -v 'deprecated' | head -1"
        local ipv6_line = sys.exec(cmd)
        if ipv6_line then
            local ipv6_addr = ipv6_line:match("inet6%s+([%x:]+)/")
            if ipv6_addr and (ipv6_addr:match("^2[0-9a-f]:") or ipv6_addr:match("^3[0-9a-f]:")) then
                ipv6_address = ipv6_addr
                result.message = "从系统获取公网IPv6地址"
            end
        end
    end
    
    if ipv6_address then
        result.ipv6_address = ipv6_address
        result.success = true
        if not result.message or result.message == "" then
            result.message = "成功获取IPv6地址"
        end
    else
        result.message = "接口 " .. interface .. " 没有可用的公网IPv6地址"
        -- 提供调试信息
        if actual_device and actual_device ~= "" then
            result.message = result.message .. " (设备: " .. actual_device .. ")"
        end
    end
    
    http.write_json(result)
end

-- 修复：检查IPv6脚本函数 - 增强兼容性
function action_check_ipv6_script()
    local req = require "luci.http"
    
    -- 设置响应类型
    req.header("Content-Type", "application/json; charset=utf-8")
    
    local result = {
        success = false,
        exists = false,
        executable = false,
        valid = false,
        message = "",
        path = ""
    }
    
    -- 获取参数
    local path = req.formvalue("path") or req.formvalue("path")
    
    -- 如果通过GET方式获取
    if not path or path == "" then
        local query_string = os.getenv("QUERY_STRING") or ""
        for param in query_string:gmatch("[^&]+") do
            local key, value = param:match("([^=]+)=?(.*)")
            if key == "path" then
                path = req.urldecode(value or "")
                break
            end
        end
    end
    
    -- 如果路径为空，使用默认值
    if not path or path == "" then
        local config = get_admin_config()
        path = config.ipv6_script_path or "/etc/openvpn/openvpn_ipv6"
    end
    
    result.path = path
    
    -- 检查文件
    local exists = (sys.call("test -f " .. path .. " 2>/dev/null") == 0)
    result.exists = exists
    
    if exists then
        -- 检查是否可执行
        result.executable = (sys.call("test -x " .. path .. " 2>/dev/null") == 0)
        
        -- 检查是否为有效的shell脚本
        local f = io.open(path, "r")
        if f then
            local first_line = f:read("*l") or ""
            f:close()
            if first_line:match("^#!/bin/sh") or first_line:match("^#!/bin/bash") or first_line:match("^#!/bin/ash") then
                result.valid = true
                result.message = "有效的shell脚本"
            else
                result.message = "不是有效的shell脚本（首行不是#!/bin/sh、#!/bin/bash或#!/bin/ash）"
            end
        else
            result.message = "无法读取文件"
        end
        
        result.success = true
    else
        result.message = "文件不存在: " .. path
        result.success = true  -- 仍然返回成功，只是文件不存在
    end
    
    req.write_json(result)
end

-- 新增：运行IPv6脚本函数
function action_run_ipv6_script()
    local req = require "luci.http"
    
    -- 设置响应类型
    req.header("Content-Type", "application/json; charset=utf-8")
    
    local result = {
        success = false,
        message = "",
        output = ""
    }
    
    local config = get_admin_config()
    local script_path = config.ipv6_script_path or "/etc/openvpn/openvpn_ipv6"
    
    -- 检查脚本是否存在
    if sys.call("test -f " .. script_path .. " 2>/dev/null") ~= 0 then
        result.message = "脚本不存在: " .. script_path
        req.write_json(result)
        return
    end
    
    -- 确保脚本有执行权限
    sys.exec("chmod +x " .. script_path .. " 2>/dev/null")
    
    -- 运行脚本并捕获输出
    local output = sys.exec(script_path .. " 2>&1")
    
    -- 记录到系统日志
    nixio.syslog("info", "OpenVPN IPv6脚本手动执行: " .. output)
    
    result.success = true
    result.message = "脚本执行完成"
    result.output = output
    
    req.write_json(result)
end

-- 设置页面
function action_settings()
    local template = require("luci.template")
    local config = get_admin_config()
    
    template.render("openvpn-admin/settings", {
        config = config
    })
end

-- 获取管理配置（AJAX接口）
function get_admin_config_ajax()
    local result = {
        success = true,
        data = get_admin_config(),
        message = ""
    }
    
    http.write_json(result)
end

-- 保存管理配置（AJAX接口）
function save_admin_config()
    local result = {
        success = false,
        message = ""
    }
    
    -- 获取所有配置参数（包含新增的）
    local params = {
        "openvpn_instance",
        "openvpn_config_path",
        "refresh_enabled",
        "refresh_interval",
        "history_size",
        "blacklist_enabled",
        "blacklist_duration",
        "blacklist_file",
        "log_file",
        "history_file",
        "easyrsa_dir",
        "easyrsa_pki",
        "openvpn_pki",
        "logs_refresh_enabled",
        "logs_refresh_interval",
        "logs_display_lines",
        "generate_client_script",
        "renew_cert_script",
        -- 新增配置项
        "temp_dir",
        "clean_garbage_enabled",
        "clean_garbage_time",
        "clean_garbage_script",
        -- 新增：IPv6脚本配置
        "ipv6_script_path",
        "ipv6_script_interval",
        "ipv6_script_enabled",
        -- 新增hotplug配置
        "hotplug_enabled",
        "hotplug_interface",
        "hotplug_ipv6_interface",
        "hotplug_ipv6_address",
        "hotplug_script_path",
        -- 新增hotplug旁路由防火墙配置项
        "hotplug_firewall_enabled",
        "hotplug_firewall_name"
    }
    
    local section = uci:get_first("openvpn-admin", "settings")
    
    if not section then
        -- 创建新的section
        uci:section("openvpn-admin", "settings", "global", {})
        section = "global"
    end
    
    -- 更新配置
    for _, param in ipairs(params) do
        local value = http.formvalue(param)
        if value then
            uci:set("openvpn-admin", section, param, value)
        end
    end
    
    -- 提交更改
    if uci:save("openvpn-admin") then
        uci:commit("openvpn-admin")
        
        -- 清除缓存
        admin_config = nil
        
        -- 更新cron任务
        update_cron_job()
        
        -- 更新IPv6定时任务
        update_ipv6_cron_job()
        
        -- -- 获取更新后的配置
        local config = get_admin_config()
        
        -- 如果启用了hotplug，创建或更新脚本
        if config.hotplug_enabled and config.hotplug_interface ~= "" then
            create_hotplug_script(config)
            -- 设置hotplug脚本的执行权限
            if config.hotplug_script_path then
                sys.exec("chmod +x " .. config.hotplug_script_path .. " 2>/dev/null")
            end
        end
        
        -- 确保临时目录存在
        sys.exec("mkdir -p " .. config.temp_dir .. " 2>/dev/null")
        
        result.success = true
        result.message = "配置保存成功"
    else
        result.message = "配置保存失败"
    end
    
    http.write_json(result)
end

-- 连接状态页面
function action_status()
    local config = get_admin_config()
    
    -- 获取OpenVPN版本
    local version = get_openvpn_version()
    
    -- 检查OpenVPN服务状态
    local service_status, service_color, service_text = check_openvpn_service()
    
    -- 通过management接口获取当前连接数据
    local connected_clients, last_activity = get_current_connections_via_management()
    local total_connected = #(connected_clients or {})
    
    -- 获取最近连接记录
    local history_size = config.history_size or 20
    local connection_history = get_recent_connection_history(history_size)
    
    -- 为每个客户端添加Client ID
    for _, client in ipairs(connected_clients or {}) do
        if not client.client_id or client.client_id == "N/A" then
            client.client_id = extract_client_id_from_management(client.name)
        end
    end
    
    -- 准备模板数据
    local template = require("luci.template")
    template.render("openvpn-admin/status", {
        last_activity = last_activity or "N/A",
        version = version,
        service_status = service_status,
        service_color = service_color,
        service_text = service_text,
        total_connected = total_connected,
        connected_clients = connected_clients or {},
        connection_history = connection_history or {},
        format_bytes = format_bytes,
        calculate_total_data = calculate_total_data,
        config = config
    })
end

-- 从management接口提取Client ID
-- 从management接口提取Client ID
function extract_client_id_from_management(client_name)
    if not client_name or client_name == "" then
        return "N/A"
    end
    
    -- 发送status命令获取状态
    local management_output = management_send_command("status 2")
    
    if management_output and management_output ~= "" then
        for line in management_output:gmatch("[^\r\n]+") do
            line = util.trim(line)
            
            if line:match("^CLIENT_LIST,") then
                local parts = util.split(line, ",")
                
                if #parts >= 13 then
                    local name = parts[2] or ""
                    if name == client_name then
                        local client_id = parts[11] or "N/A"
                        return client_id
                    end
                end
            end
        end
    end
    
    return "N/A"
end

-- 日志页面
function action_logs()
    local config = get_admin_config()
    
    -- 获取日志页面配置
    local logs_config = get_logs_config()
    
    -- 读取日志内容
    local log_content = ""
    local logs_display_lines = logs_config.display_lines or 1000
    local log_file = config.log_file or "/tmp/openvpn.log"
    
    if sys.call("test -f " .. log_file .. " 2>/dev/null") == 0 then
        -- 直接使用tail读取，不使用tac命令
        local content = sys.exec("tail -" .. logs_display_lines .. " " .. log_file .. " 2>/dev/null")
        if content and content ~= "" then
            -- 使用Lua代码反转行顺序，让最新日志在最上面
            local lines = util.split(content, "\n")
            local reversed_lines = {}
            for i = #lines, 1, -1 do
                table.insert(reversed_lines, lines[i])
            end
            log_content = table.concat(reversed_lines, "\n")
        end
    else
        log_content = "日志文件不存在: " .. log_file
    end
    
    -- 准备模板数据
    local template = require("luci.template")
    template.render("openvpn-admin/logs", {
        config = config,
        logs_config = logs_config,
        log_content = log_content,
        logs_display_lines = logs_display_lines
    })
end

-- 获取OpenVPN日志（AJAX接口）- 修复版，不使用tac命令
function get_openvpn_logs()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    local log_file = get_log_file()
    local config = get_admin_config()
    local logs_display_lines = config.logs_display_lines or 1000
    
    if sys.call("test -f " .. log_file .. " 2>/dev/null") == 0 then
        -- 使用安全的读取方式，避免使用tac命令
        local content = ""
        
        -- 使用tail命令读取
        content = sys.exec("tail -" .. logs_display_lines .. " " .. log_file .. " 2>/dev/null")
        
        if content and content ~= "" then
            -- 使用Lua代码反转行顺序，让最新日志在最上面
            local lines = util.split(content, "\n")
            local reversed_lines = {}
            for i = #lines, 1, -1 do
                table.insert(reversed_lines, lines[i])
            end
            content = table.concat(reversed_lines, "\n")
            
            result.data.log_content = content
            result.success = true
        else
            result.message = "无法读取日志文件"
        end
    else
        result.message = "日志文件不存在"
    end
    
    http.write_json(result)
end

-- 清除OpenVPN日志
function clear_openvpn_logs()
    local result = {
        success = false,
        message = ""
    }
    
    local log_file = get_log_file()
    
    -- 清空日志文件
    local ret = sys.call("echo '' > " .. log_file .. " 2>/dev/null")
    
    if ret == 0 then
        result.success = true
        result.message = "日志已清空"
    else
        result.message = "日志清空失败"
    end
    
    http.write_json(result)
end

-- 下载OpenVPN日志
function download_openvpn_logs()
    local filename = get_log_file()
    
    if sys.call("test -f " .. filename .. " 2>/dev/null") == 0 then
        local content = sys.exec("cat " .. filename .. " 2>/dev/null")
        
        -- 设置HTTP头以下载文件
        http.header('Content-Type', 'text/plain')
        http.header('Content-Disposition', 'attachment; filename="openvpn.log"')
        http.header('Content-Length', tostring(#content))
        
        http.write(content)
    else
        http.status(404, "File not found")
        http.write("日志文件不存在")
    end
end

-- 获取OpenVPN状态信息（AJAX接口）
function get_openvpn_status()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    -- 获取OpenVPN版本
    local version = get_openvpn_version()
    
    -- 检查OpenVPN服务状态
    local service_status, service_color, service_text = check_openvpn_service()
    
    -- 通过management接口获取当前连接数据
    local connected_clients, last_activity = get_current_connections_via_management()
    
    -- 为每个客户端添加Client ID
    for _, client in ipairs(connected_clients or {}) do
        if not client.client_id or client.client_id == "N/A" then
            client.client_id = extract_client_id_from_management(client.name)
        end
    end
    
    -- 获取最近连接记录
    local config = get_admin_config()
    local history_size = config.history_size or 20
    local connection_history = get_recent_connection_history(history_size)
    
    -- 获取客户端黑名单
    local blacklist_config = get_blacklist_config()
    local blacklist_cn = {}
    
    if blacklist_config.enabled then
        blacklist_cn = get_client_blacklist_cn()
    end
    
    result.data = {
        version = version,
        service_status = service_status,
        service_color = service_color,
        service_text = service_text,
        last_activity = last_activity or "N/A",
        connected_clients = connected_clients or {},
        total_connected = #(connected_clients or {}),
        connection_history = connection_history or {},
        blacklist_cn = blacklist_cn or {},
        refresh_interval = get_refresh_interval()
    }
    
    result.success = true
    http.write_json(result)
end

-- 获取OpenVPN版本信息
function get_openvpn_version()
    local version = "N/A"
    local version_output = sys.exec("openvpn --version 2>/dev/null | head -1")
    
    if version_output and version_output ~= "" then
        local match = version_output:match("OpenVPN ([%d%.]+)")
        if match then
            version = "OpenVPN " .. match
        else
            version = util.trim(version_output)
            if #version > 50 then
                version = version:sub(1, 47) .. "..."
            end
        end
    end
    
    if type(version) == "table" then
        version = tostring(version)
    elseif type(version) ~= "string" then
        version = "N/A"
    end
    
    return version
end

-- 从OpenVPN配置文件中获取management接口配置（无日志版本）
-- 从OpenVPN配置文件中获取management接口配置（强制使用Unix Domain Socket）
-- 从OpenVPN配置文件中获取management接口配置（根据openvpn-admin配置的实例名）
-- 从OpenVPN配置文件中获取management接口配置（Unix Domain Socket专用）
function get_openvpn_management_config()
    local management_socket = ""  -- 初始为空
    local management_ip = ""      -- 保留但不再使用
    local management_port = ""    -- 保留但不再使用
    
    -- 1. 从openvpn-admin配置获取实例名
    local instance = get_openvpn_instance()
    
    if not instance or instance == "" then
        nixio.syslog("err", "未配置openvpn_instance")
        return management_ip, management_port, management_socket
    end
    
    nixio.syslog("debug", "OpenVPN实例名: " .. instance)
    
    -- 2. 从openvpn配置读取management配置
    local uci = require("luci.model.uci").cursor()
    
    -- 检查实例是否存在
    local exists = uci:get("openvpn", instance)
    if not exists then
        nixio.syslog("err", "OpenVPN实例不存在: " .. instance)
        return management_ip, management_port, management_socket
    end
    
    -- 获取management配置
    local uci_management = uci:get("openvpn", instance, "management")
    
    if uci_management and uci_management ~= "" then
        nixio.syslog("debug", "原始management配置: " .. uci_management)
        
        -- 检查是否为Unix Domain Socket格式（以/开头）
        if uci_management:match("^/") then
            -- 提取纯路径部分（去掉后面的 "unix" 关键字）
            local pure_path = uci_management:match("^(/[^%s]+)")
            if pure_path then
                management_socket = pure_path
                nixio.syslog("info", "从配置获取Unix Socket路径: " .. management_socket)
            else
                management_socket = uci_management
                nixio.syslog("warning", "Unix Socket格式可能不正确: " .. management_socket)
            end
        else
            -- 如果不是Unix Socket格式，可能是旧的TCP配置，使用默认值
            management_socket = "/var/run/openvpn.sock unix"
            nixio.syslog("warning", "management配置不是Unix Socket格式，使用默认路径: " .. management_socket)
        end
    else
        nixio.syslog("warning", "实例 " .. instance .. " 未配置management选项，使用默认路径")
        management_socket = "/var/run/openvpn.sock unix"
    end
    
    return management_ip, management_port, management_socket
end

-- ======================================================
-- 新增函数：management_send_command()
-- 功能：统一发送命令到OpenVPN management接口
-- 支持：Unix Domain Socket 和 TCP 两种方式
-- ======================================================
-- 统一发送命令到OpenVPN management接口（仅支持Unix Domain Socket）
-- 发送命令到OpenVPN management接口（仅支持Unix Domain Socket）
function management_send_command(command)
    local result = ""
    
    -- 获取management配置
    local mgmt_ip, mgmt_port, mgmt_socket = get_openvpn_management_config()
    
    nixio.syslog("debug", "management_send_command: command=" .. command .. ", socket=" .. mgmt_socket)
    
    -- 检查是否获取到socket路径
    if not mgmt_socket or mgmt_socket == "" then
        nixio.syslog("err", "未获取到Unix Socket路径")  -- 修改: error -> err
        return ""
    end
    
    -- 检查socket文件是否存在
    if sys.call("test -S " .. mgmt_socket .. " 2>/dev/null") ~= 0 then
        nixio.syslog("err", "Unix Socket文件不存在: " .. mgmt_socket)  -- 修改: error -> err
        return ""
    end
    
    -- 检查socat是否可用
    if sys.call("which socat >/dev/null 2>&1") ~= 0 then
        nixio.syslog("err", "socat命令不存在，无法连接Unix Socket")  -- 修改: error -> err
        return ""
    end
    
    -- 创建临时文件
    local tmp_cmd = "/tmp/openvpn-mgmt-cmd.tmp"
    local tmp_out = "/tmp/openvpn-mgmt-out.tmp"
    
    -- 清理旧文件
    sys.exec("rm -f " .. tmp_cmd .. " " .. tmp_out .. " 2>/dev/null")
    
    -- 写入命令
    local fd = io.open(tmp_cmd, "w")
    if fd then
        fd:write(command .. "\n")
        fd:close()
    else
        nixio.syslog("err", "无法创建临时命令文件")  -- 这行已经是正确的 "err"
        return ""
    end
    
    -- 使用socat发送命令
    local socat_cmd = string.format("cat %s | socat -T 2 - UNIX-CONNECT:%s 2>/dev/null | head -n 50 > %s", 
                                    tmp_cmd, mgmt_socket, tmp_out)
    nixio.syslog("debug", "执行: " .. socat_cmd)
    
    sys.call(socat_cmd)
    
    -- 读取输出
    if sys.call("test -f " .. tmp_out .. " 2>/dev/null") == 0 then
        local out_fd = io.open(tmp_out, "r")
        if out_fd then
            result = out_fd:read("*a") or ""
            out_fd:close()
        end
        sys.exec("rm -f " .. tmp_out)
    end
    
    -- 清理
    sys.exec("rm -f " .. tmp_cmd)
    
    return result
end

-- 从OpenVPN配置文件中获取端口和协议
function get_openvpn_port_and_proto()
    local port = 1194
    local proto = "udp"
    
    local instance = get_openvpn_instance()
    
    -- 尝试从uci配置中获取
    local uci_port = sys.exec(string.format("uci -q get openvpn.%s.port 2>/dev/null", instance))
    local uci_proto = sys.exec(string.format("uci -q get openvpn.%s.proto 2>/dev/null", instance))
    
    if uci_port and uci_port ~= "" then
        port = tonumber(util.trim(uci_port)) or port
    end
    
    if uci_proto and uci_proto ~= "" then
        proto = util.trim(uci_proto)
    end
    
    -- 如果uci获取失败，尝试从配置文件直接读取
    if port == 1194 and proto == "udp" then
        local config_path = get_openvpn_config_path()
        if sys.call("test -f " .. config_path .. " 2>/dev/null") == 0 then
            local config_content = sys.exec("cat " .. config_path .. " 2>/dev/null")
            if config_content then
                local in_correct_instance = false
                local instance_name = "'" .. instance .. "'"
                
                for line in config_content:gmatch("[^\r\n]+") do
                    local trimmed = util.trim(line)
                    
                    if trimmed:match("^config openvpn ") and trimmed:match(instance_name) then
                        in_correct_instance = true
                    elseif in_correct_instance and trimmed:match("^config ") then
                        in_correct_instance = false
                    end
                    
                    if in_correct_instance then
                        if trimmed:match("^option%s+port%s+") then
                            local match = trimmed:match("'([^']+)'") or trimmed:match('"([^"]+)"')
                            if match then
                                port = tonumber(match) or port
                            end
                        elseif trimmed:match("^option%s+proto%s+") then
                            local match = trimmed:match("'([^']+)'") or trimmed:match('"([^"]+)"')
                            if match then
                                proto = match:lower()
                            end
                        end
                    end
                end
            end
        end
    end
    
    return port, proto
end

-- 简化的OpenVPN状态检查（检查进程端口）
function check_openvpn_service()
    local service_status = "stopped"
    local service_color = "red"
    local service_text = "已停止"
    
    -- 1. 先检查进程是否存在
    local process_found = false
    local pid = nil
    
    -- 使用更精确的grep命令，排除grep进程
    local ps_cmd = "ps | grep -v grep | grep 'openvpn' | head -1"
    local ps_result = sys.exec(ps_cmd)
    
    if ps_result and ps_result ~= "" then
        -- 提取PID
        pid = ps_result:match("^%s*(%d+)")
        if pid then
            process_found = true
        end
    end
    
    -- 备用方法：使用pgrep
    if not process_found then
        local pgrep_result = sys.exec("pgrep -f 'openvpn' 2>/dev/null")
        if pgrep_result and pgrep_result ~= "" then
            pid = util.trim(pgrep_result):match("%d+")
            if pid then
                process_found = true
            end
        end
    end
    
    if process_found then
        -- 2. 检查端口是否在监听（关键修复）
        local port_listening = false
        local port, proto = get_openvpn_port_and_proto()
        
        if port then
            -- 检查IPv4端口监听
            local netstat_cmd = string.format("netstat -ulnp 2>/dev/null | grep ':%s ' | grep %s", port, pid)
            local netstat_result = sys.exec(netstat_cmd)
            
            -- 检查IPv6端口监听
            local netstat_cmd6 = string.format("netstat -ulnp 2>/dev/null | grep ':%s ' | grep %s", port, pid)
            local netstat_result6 = sys.exec(netstat_cmd6)
            
            -- 尝试ss命令
            local ss_cmd = string.format("ss -ulnp 2>/dev/null | grep ':%s' | grep pid=%s", port, pid)
            local ss_result = sys.exec(ss_cmd)
            
            if (netstat_result and netstat_result ~= "") or 
               (netstat_result6 and netstat_result6 ~= "") or
               (ss_result and ss_result ~= "") then
                port_listening = true
            end
            
            -- 如果还是没找到，可能是IPv6格式问题，用更通用的检查
            if not port_listening then
                local simple_check = sys.exec(string.format("netstat -anp 2>/dev/null | grep :%s | grep %s", port, pid))
                if simple_check and simple_check ~= "" then
                    port_listening = true
                end
            end
        end
        
        if port_listening then
            service_status = "running"
            service_color = "green"
            service_text = "运行中"
        else
            -- 进程存在但没有监听端口，可能是启动失败
            service_status = "error"
            service_color = "orange"
            service_text = "进程存在但端口未监听"
        end
    else
        service_status = "stopped"
        service_color = "red"
        service_text = "已停止"
    end
    
    return service_status, service_color, service_text
end

-- 通过management接口获取当前连接数据
-- 通过management接口获取当前连接数据
function get_current_connections_via_management()
    local connected_clients = {}
    local last_activity = "N/A"
    
    -- 发送status命令获取状态
    local management_output = management_send_command("status 2")
    
    if management_output and management_output ~= "" then
        last_activity = os.date("%Y-%m-%d %H:%M:%S")
        
        for line in management_output:gmatch("[^\r\n]+") do
            line = util.trim(line)
            
            if line:match("^CLIENT_LIST,") then
                local parts = util.split(line, ",")
                
                if #parts >= 13 then
                    local client_name = parts[2] or "N/A"
                    local real_address = parts[3] or "N/A"
                    local virtual_address = parts[4] or "N/A"
                    local bytes_received = tonumber(parts[6]) or 0
                    local bytes_sent = tonumber(parts[7]) or 0
                    local connect_time_str = parts[8] or ""
                    local connect_timestamp = tonumber(parts[9]) or os.time()
                    local client_id = parts[11] or "N/A"
                    local cipher = parts[13] or "N/A"
                    
                    -- 修复接收数据为0的问题
                    if bytes_received == 0 and bytes_sent > 0 then
                        bytes_received, bytes_sent = bytes_sent, bytes_received
                    end
                    
                    -- 计算连接时长
                    local current_time = os.time()
                    local duration_seconds = current_time - connect_timestamp
                    local duration_str = format_duration(duration_seconds)
                    
                    -- 格式化连接时间
                    local connect_time_formatted = ""
                    if connect_time_str ~= "" then
                        local timestamp_num = tonumber(connect_time_str)
                        if timestamp_num then
                            connect_time_formatted = os.date("%Y-%m-d %H:%M:%S", timestamp_num)
                        else
                            connect_time_formatted = connect_time_str
                        end
                    else
                        connect_time_formatted = os.date("%Y-%m-%d %H:%M:%S", connect_timestamp)
                    end
                    
                    local client = {
                        name = client_name,
                        real_address = real_address,
                        virtual_address = virtual_address,
                        bytes_received = bytes_received,
                        bytes_sent = bytes_sent,
                        connect_time = connect_time_str,
                        connect_time_formatted = connect_time_formatted,
                        connect_timestamp = connect_timestamp,
                        cipher = cipher,
                        duration = duration_str,
                        duration_seconds = duration_seconds,
                        total_data = bytes_received + bytes_sent,
                        client_id = client_id
                    }
                    table.insert(connected_clients, client)
                end
            end
        end
    else
        -- 如果management接口不可用，尝试从状态文件读取
        local status_file = "/tmp/openvpn-status.log"
        
        if sys.call("test -f " .. status_file .. " 2>/dev/null") == 0 then
            local status_content = sys.exec("cat " .. status_file .. " 2>/dev/null")
            
            if status_content and status_content ~= "" then
                last_activity = os.date("%Y-%m-%d %H:%M:%S")
                
                for line in status_content:gmatch("[^\r\n]+") do
                    line = util.trim(line)
                    
                    if line:match("^CLIENT_LIST,") then
                        local parts = util.split(line, ",")
                        
                        if #parts >= 13 then
                            local client_name = parts[2] or "N/A"
                            local real_address = parts[3] or "N/A"
                            local virtual_address = parts[4] or "N/A"
                            local bytes_received = tonumber(parts[6]) or 0
                            local bytes_sent = tonumber(parts[7]) or 0
                            local connect_time = parts[8] or "N/A"
                            local client_id = parts[11] or "N/A"
                            local cipher = parts[13] or "N/A"
                            
                            local connect_timestamp = os.time()
                            if connect_time ~= "N/A" then
                                local year, month, day, hour, min, sec = connect_time:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
                                if year then
                                    connect_timestamp = os.time{year=year, month=month, day=day, hour=hour, min=min, sec=sec}
                                else
                                    local ts = tonumber(connect_time)
                                    if ts then
                                        connect_timestamp = ts
                                        connect_time = os.date("%Y-%m-%d %H:%M:%S", ts)
                                    end
                                end
                            end
                            
                            local current_time = os.time()
                            local duration_seconds = current_time - connect_timestamp
                            local duration_str = format_duration(duration_seconds)
                            
                            local client = {
                                name = client_name,
                                real_address = real_address,
                                virtual_address = virtual_address,
                                bytes_received = bytes_received,
                                bytes_sent = bytes_sent,
                                connect_time = connect_time,
                                connect_time_formatted = connect_time,
                                connect_timestamp = connect_timestamp,
                                cipher = cipher,
                                duration = duration_str,
                                duration_seconds = duration_seconds,
                                total_data = bytes_received + bytes_sent,
                                client_id = client_id
                            }
                            table.insert(connected_clients, client)
                        end
                    end
                end
            end
        end
    end
    
    -- 更新连接记录
    update_connection_history(connected_clients)
    
    return connected_clients, last_activity
end

-- 格式化时长函数
function format_duration(seconds)
    if not seconds or seconds <= 0 then
        return "0秒"
    end
    
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    
    local parts = {}
    
    if days > 0 then
        table.insert(parts, days .. "天")
    end
    if hours > 0 then
        table.insert(parts, hours .. "小时")
    end
    if minutes > 0 then
        table.insert(parts, minutes .. "分钟")
    end
    if secs > 0 or #parts == 0 then
        table.insert(parts, secs .. "秒")
    end
    
    return table.concat(parts)
end

-- 获取最近连接记录
function get_recent_connection_history(limit)
    local history_file = get_history_file()
    local history_data = {}
    
    -- 如果文件不存在，尝试创建目录和文件
    if sys.call("test -f " .. history_file .. " 2>/dev/null") ~= 0 then
        -- 创建目录
        local dir = history_file:match("^(.*/)[^/]*$")
        if dir then
            sys.exec("mkdir -p " .. dir .. " 2>/dev/null")
        end
        -- 创建空文件
        sys.exec("echo '[]' > " .. history_file .. " 2>/dev/null")
    end
    
    if sys.call("test -f " .. history_file .. " 2>/dev/null") == 0 then
        local history_content = sys.exec("cat " .. history_file .. " 2>/dev/null")
        if history_content and history_content ~= "" then
            local ok, data = pcall(json.parse, history_content)
            if ok and type(data) == "table" then
                history_data = data
                
                -- 为每条记录添加格式化时间
                for _, record in ipairs(history_data) do
                    if record.connect_timestamp then
                        record.connect_time_formatted = os.date("%Y-%m-%d %H:%M:%S", record.connect_timestamp)
                    end
                    if record.disconnect_timestamp and record.disconnect_timestamp > 0 then
                        record.disconnect_time_formatted = os.date("%Y-%m-%d %H:%M:%S", record.disconnect_timestamp)
                    end
                end
                
                -- 按连接时间倒序排序
                table.sort(history_data, function(a, b)
                    return (a.connect_timestamp or 0) > (b.connect_timestamp or 0)
                end)
            end
        end
    end
    
    -- 限制返回的记录数量
    if limit and #history_data > limit then
        local limited_history = {}
        for i = 1, math.min(limit, #history_data) do
            table.insert(limited_history, history_data[i])
        end
        return limited_history
    end
    
    return history_data
end

-- 更新连接记录
function update_connection_history(current_connections)
    local config = get_admin_config()
    local history_file = config.history_file
    local max_records = config.history_size or 20
    
    local history_data = get_recent_connection_history(nil)
    local current_time = os.time()
    local current_ids = {}
    
    -- 为当前连接生成ID
    for _, conn in ipairs(current_connections) do
        local connection_id = generate_connection_id(conn.name, conn.real_address, conn.connect_time)
        current_ids[connection_id] = true
        
        local found = false
        for _, record in ipairs(history_data) do
            if record.connection_id == connection_id then
                -- 更新现有记录
                record.bytes_received = conn.bytes_received
                record.bytes_sent = conn.bytes_sent
                record.total_data = conn.total_data
                record.is_connected = true
                record.disconnect_time = ""
                record.disconnect_time_formatted = ""
                record.disconnect_timestamp = 0
                record.cipher = conn.cipher or "N/A"
                record.duration = conn.duration
                record.duration_seconds = conn.duration_seconds
                record.client_id = conn.client_id or "N/A"
                found = true
                break
            end
        end
        
        if not found then
            -- 添加新记录
            table.insert(history_data, {
                name = conn.name,
                real_address = conn.real_address,
                virtual_address = conn.virtual_address,
                connect_time = conn.connect_time,
                connect_time_formatted = conn.connect_time_formatted,
                connect_timestamp = conn.connect_timestamp,
                disconnect_time = "",
                disconnect_time_formatted = "",
                disconnect_timestamp = 0,
                bytes_received = conn.bytes_received,
                bytes_sent = conn.bytes_sent,
                total_data = conn.total_data,
                is_connected = true,
                connection_id = connection_id,
                cipher = conn.cipher or "N/A",
                duration = conn.duration,
                duration_seconds = conn.duration_seconds,
                client_id = conn.client_id or "N/A"
            })
        end
    end
    
    -- 标记已断开的连接
    for _, record in ipairs(history_data) do
        if record.is_connected and not current_ids[record.connection_id] then
            if record.disconnect_time == "" then
                record.is_connected = false
                record.disconnect_time = os.date("%Y-%m-%d %H:%M:%S", current_time)
                record.disconnect_time_formatted = record.disconnect_time
                record.disconnect_timestamp = current_time
                if record.connect_timestamp and record.connect_timestamp > 0 then
                    record.duration_seconds = current_time - record.connect_timestamp
                    record.duration = format_duration(record.duration_seconds)
                end
            end
        end
    end
    
    -- 按连接时间倒序排序
    table.sort(history_data, function(a, b)
        return (a.connect_timestamp or 0) > (b.connect_timestamp or 0)
    end)
    
    -- 限制记录数量
    if #history_data > max_records then
        local new_history = {}
        for i = 1, max_records do
            table.insert(new_history, history_data[i])
        end
        history_data = new_history
    end
    
    -- 保存更新后的历史记录
    if #history_data > 0 then
        local json_data = json.stringify(history_data, true)
        local temp_file = "/tmp/openvpn_history.tmp"
        local temp_fd = io.open(temp_file, "w")
        if temp_fd then
            temp_fd:write(json_data)
            temp_fd:close()
            sys.exec("mv " .. temp_file .. " " .. history_file .. " 2>/dev/null")
        end
    end
end

-- 生成连接ID
function generate_connection_id(name, address, time_str)
    local str = (name or "") .. (address or "") .. (time_str or "")
    
    local md5_output = sys.exec("echo -n '" .. str:gsub("'", "'\\''") .. "' | md5sum 2>/dev/null | cut -d' ' -f1")
    
    if md5_output and md5_output ~= "" then
        return util.trim(md5_output)
    else
        local hash = 0
        for i = 1, #str do
            hash = (hash * 31 + string.byte(str, i)) % 0x7FFFFFFF
        end
        return tostring(hash)
    end
end

-- 启动OpenVPN服务
function start_openvpn_service()
    local result = set_openvpn_service_state(true)
    http.write_json(result)
end

-- 停止OpenVPN服务
function stop_openvpn_service()
    local result = set_openvpn_service_state(false)
    http.write_json(result)
end

-- 断开客户端连接
-- 断开客户端连接
function disconnect_client()
    local result = {
        success = false,
        message = "",
        debug_info = ""
    }
    
    local client_name = http.formvalue("client_name")
    local real_address = http.formvalue("real_address")
    local client_id = http.formvalue("client_id")
    
    nixio.syslog("info", "OpenVPN断开连接请求: client_name=" .. (client_name or "nil") .. 
                 ", real_address=" .. (real_address or "nil") .. 
                 ", client_id=" .. (client_id or "nil"))
    
    if not client_name or client_name == "" or client_name == "nil" then
        result.message = "客户端名称为空"
        http.write_json(result)
        return
    end
    
    local actual_client_id = client_id
    
    if actual_client_id then
        actual_client_id = actual_client_id:match("%d+") or actual_client_id
    end
    
    -- 如果Client ID无效，尝试通过management接口查找
    if not actual_client_id or actual_client_id == "" or actual_client_id == "nil" or actual_client_id == "N/A" then
        nixio.syslog("info", "Client ID无效，尝试通过management接口查找: " .. client_name)
        
        -- 获取完整的status信息并查找客户端
        local management_output = management_send_command("status 2")
        
        if management_output and management_output ~= "" then
            for line in management_output:gmatch("[^\r\n]+") do
                if line:match("CLIENT_LIST") and line:match(client_name) then
                    local fields = util.split(line, ",")
                    if #fields >= 11 then
                        actual_client_id = fields[11] or "N/A"
                        nixio.syslog("info", "找到Client ID: " .. actual_client_id)
                        break
                    end
                end
            end
        else
            nixio.syslog("warning", "无法通过management接口获取状态")
        end
    end
    
    if actual_client_id then
        actual_client_id = actual_client_id:match("%d+") or actual_client_id
    end
    
    if not actual_client_id or actual_client_id == "" or actual_client_id == "N/A" then
        result.message = "无法找到客户端的Client ID"
        result.debug_info = "客户端名称: " .. client_name
        http.write_json(result)
        return
    end
    
    nixio.syslog("info", "准备断开连接: client=" .. client_name .. ", client_id=" .. actual_client_id)
    
    -- 尝试第一种方式：client-kill
    local kill_command = "client-kill " .. actual_client_id
    local output = management_send_command(kill_command)
    
    if output and (output:match("SUCCESS") or output:match("INFO") or output:match("client%-kill")) then
        result.success = true
        result.message = "客户端 '" .. client_name .. "' 已断开"
        
        -- 将客户端添加到黑名单
        local blacklist_config = get_blacklist_config()
        if blacklist_config.enabled then
            add_client_to_blacklist_cn(client_name, blacklist_config.duration, "手动断开")
        end
        
        nixio.syslog("info", "断开连接成功: " .. client_name .. " (ID: " .. actual_client_id .. ")")
    else
        -- 尝试第二种方式：kill
        kill_command = "kill " .. actual_client_id
        output = management_send_command(kill_command)
        
        if output and (output:match("SUCCESS") or output:match("INFO") or output:match("kill")) then
            result.success = true
            result.message = "客户端 '" .. client_name .. "' 已断开"
            
            local blacklist_config = get_blacklist_config()
            if blacklist_config.enabled then
                add_client_to_blacklist_cn(client_name, blacklist_config.duration, "手动断开")
            end
            
            nixio.syslog("info", "使用kill命令断开连接成功: " .. client_name .. " (ID: " .. actual_client_id .. ")")
        else
            result.message = "无法断开客户端 '" .. client_name .. "' 的连接"
            result.debug_info = "Client ID: " .. actual_client_id .. ", 输出: " .. (output or "无输出")
            nixio.syslog("err", "断开连接失败: " .. result.message)
        end
    end
    
    http.write_json(result)
end

-- 通过客户端名查找Client ID
-- 通过客户端名查找Client ID
function find_client_id_by_name(client_name)
    if not client_name or client_name == "" then
        return nil
    end
    
    local management_output = management_send_command("status 2")
    
    if management_output and management_output ~= "" then
        for line in management_output:gmatch("[^\r\n]+") do
            line = util.trim(line)
            
            if line:match("^CLIENT_LIST,") then
                local parts = util.split(line, ",")
                
                if #parts >= 13 then
                    local name = parts[2] or ""
                    if name == client_name then
                        local client_id = parts[11] or "N/A"
                        return client_id
                    end
                end
            end
        end
    end
    
    return nil
end

-- 查找客户端的Client ID（AJAX接口）
-- 查找客户端的Client ID（AJAX接口）
function find_client_id()
    local result = {
        success = false,
        client_id = "N/A",
        message = ""
    }
    
    local client_name = http.formvalue("client_name")
    
    if not client_name or client_name == "" then
        result.message = "客户端名称为空"
        http.write_json(result)
        return
    end
    
    local found_client_id = find_client_id_by_name(client_name)
    
    if found_client_id and found_client_id ~= "N/A" then
        result.success = true
        result.client_id = found_client_id
        result.message = "找到Client ID"
    else
        result.message = "未找到客户端的Client ID"
    end
    
    http.write_json(result)
end
-- 将客户端添加到黑名单（基于CN）
function add_client_to_blacklist_cn(client_cn, duration_seconds, reason)
    if not client_cn or client_cn == "" then return false end
    
    reason = reason or "手动断开"
    
    local blacklist_config = get_blacklist_config()
    duration_seconds = duration_seconds or blacklist_config.duration
    
    local current_time = os.time()
    local expiry_time = current_time + duration_seconds
    
    -- 读取现有黑名单
    local blacklist_file = blacklist_config.file
    local blacklist = {version = 1, entries = {}}
    
    if sys.call("test -f " .. blacklist_file .. " 2>/dev/null") == 0 then
        local blacklist_content = sys.exec("cat " .. blacklist_file .. " 2>/dev/null")
        if blacklist_content and blacklist_content ~= "" then
            local ok, data = pcall(json.parse, blacklist_content)
            if ok and data and data.entries then
                blacklist = data
            end
        end
    end
    
    -- 检查是否已存在
    local found = false
    for i, entry in ipairs(blacklist.entries) do
        if entry.cn == client_cn then
            blacklist.entries[i] = {
                cn = client_cn,
                added_time = current_time,
                expiry_time = expiry_time,
                duration = duration_seconds,
                reason = reason,
                added_time_formatted = os.date("%Y-%m-%d %H:%M:%S", current_time),
                expiry_time_formatted = os.date("%Y-%m-%d %H:%M:%S", expiry_time)
            }
            found = true
            break
        end
    end
    
    if not found then
        table.insert(blacklist.entries, {
            cn = client_cn,
            added_time = current_time,
            expiry_time = expiry_time,
            duration = duration_seconds,
            reason = reason,
            added_time_formatted = os.date("%Y-%m-%d %H:%M:%S", current_time),
            expiry_time_formatted = os.date("%Y-%m-%d %H:%M:%S", expiry_time)
        })
    end
    
    -- 保存黑名单
    return save_blacklist_cn(blacklist)
end

-- 保存黑名单到文件（基于CN）
function save_blacklist_cn(blacklist_data)
    local blacklist_config = get_blacklist_config()
    local blacklist_file = blacklist_config.file
    local json_data = json.stringify(blacklist_data, true)
    local temp_file = "/tmp/blacklist_cn.tmp"
    
    local temp_fd = io.open(temp_file, "w")
    if temp_fd then
        temp_fd:write(json_data)
        temp_fd:close()
        sys.exec("mv " .. temp_file .. " " .. blacklist_file .. " 2>/dev/null")
        sys.exec("chmod 644 " .. blacklist_file .. " 2>/dev/null")
        return true
    end
    return false
end

-- 获取客户端黑名单（基于CN）
function get_client_blacklist_cn()
    local blacklist_config = get_blacklist_config()
    local blacklist_file = blacklist_config.file
    local blacklist_entries = {}
    local current_time = os.time()
    local need_update = false
    
    -- 读取黑名单文件
    if sys.call("test -f " .. blacklist_file .. " 2>/dev/null") == 0 then
        local blacklist_content = sys.exec("cat " .. blacklist_file .. " 2>/dev/null")
        if blacklist_content and blacklist_content ~= "" then
            local ok, data = pcall(json.parse, blacklist_content)
            if ok and data and data.entries then
                for _, entry in ipairs(data.entries) do
                    if entry.expiry_time and entry.expiry_time > current_time then
                        entry.remaining_seconds = entry.expiry_time - current_time
                        entry.remaining_time = format_duration(entry.remaining_seconds)
                        entry.status = "active"
                        table.insert(blacklist_entries, entry)
                    else
                        need_update = true
                    end
                end
            end
        end
    end
    
    -- 如果需要更新，保存更新后的黑名单
    if need_update then
        local blacklist_data = {version = 1, entries = blacklist_entries}
        save_blacklist_cn(blacklist_data)
    end
    
    return blacklist_entries
end

-- 获取黑名单列表（AJAX接口）- 基于CN
function get_blacklist_cn()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    local blacklist_config = get_blacklist_config()
    
    if not blacklist_config.enabled then
        result.message = "黑名单功能已禁用"
        http.write_json(result)
        return
    end
    
    local blacklist = get_client_blacklist_cn()
    
    result.data = blacklist
    result.success = true
    
    http.write_json(result)
end

-- 从黑名单中移除客户端（基于CN）- AJAX接口
function remove_from_blacklist_cn()
    local client_cn = http.formvalue("cn")
    local result = {success = false, message = ""}
    
    if not client_cn or client_cn == "" then
        result.message = "客户端CN不能为空"
        http.write_json(result)
        return
    end
    
    local blacklist_config = get_blacklist_config()
    local blacklist_file = blacklist_config.file
    local blacklist = {version = 1, entries = {}}
    
    -- 读取现有黑名单
    if sys.call("test -f " .. blacklist_file .. " 2>/dev/null") == 0 then
        local blacklist_content = sys.exec("cat " .. blacklist_file .. " 2>/dev/null")
        if blacklist_content and blacklist_content ~= "" then
            local ok, data = pcall(json.parse, blacklist_content)
            if ok and data and data.entries then
                blacklist = data
            end
        end
    end
    
    -- 过滤掉要移除的客户端
    local new_entries = {}
    for _, entry in ipairs(blacklist.entries) do
        if entry.cn ~= client_cn then
            table.insert(new_entries, entry)
        end
    end
    
    blacklist.entries = new_entries
    
    -- 保存更新后的黑名单
    if save_blacklist_cn(blacklist) then
        result.success = true
        result.message = "客户端 '" .. client_cn .. "' 已从黑名单中移除"
        nixio.syslog("info", "OpenVPN黑名单: 从黑名单移除客户端 " .. client_cn)
    else
        result.message = "保存黑名单失败"
    end
    
    http.write_json(result)
end

-- 添加客户端到黑名单（基于CN）- AJAX接口
function add_client_to_blacklist()
    local result = {
        success = false,
        message = ""
    }
    
    local blacklist_config = get_blacklist_config()
    
    if not blacklist_config.enabled then
        result.message = "黑名单功能已禁用"
        http.write_json(result)
        return
    end
    
    local cn = http.formvalue("cn")
    local duration = http.formvalue("duration")
    
    if not cn or cn == "" then
        result.message = "客户端CN不能为空"
        http.write_json(result)
        return
    end
    
    if not cn:match("^[%w_%-%.]+$") then
        result.message = "客户端CN格式不正确，只允许字母、数字、下划线、短横线和点"
        http.write_json(result)
        return
    end
    
    local duration_seconds = blacklist_config.duration
    if duration then
        if duration == "1min" then
            duration_seconds = 60
        elseif duration == "5min" then
            duration_seconds = 300
        elseif duration == "10min" then
            duration_seconds = 600
        elseif duration == "1hour" then
            duration_seconds = 3600
        elseif duration == "permanent" then
            duration_seconds = 31536000
        end
    end
    
    if add_client_to_blacklist_cn(cn, duration_seconds, "手动添加") then
        result.success = true
        result.message = "客户端 '" .. cn .. "' 已添加到黑名单"
        nixio.syslog("info", "OpenVPN黑名单: 添加客户端 " .. cn .. " 到黑名单")
    else
        result.message = "添加黑名单失败"
    end
    
    http.write_json(result)
end

-- 获取OpenVPN配置文件内容 (AJAX接口)
function get_openvpn_config()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    local config_path = get_openvpn_config_path()
    
    if sys.call("test -f " .. config_path .. " 2>/dev/null") == 0 then
        local content = sys.exec("cat " .. config_path .. " 2>/dev/null")
        if content and content ~= "" then
            content = util.trim(content)
            
            local line_count = 0
            for _ in content:gmatch("[^\n]+") do
                line_count = line_count + 1
            end
            
            local char_count = #content
            
            result.data = {
                content = content,
                line_count = line_count,
                char_count = char_count
            }
            result.success = true
        else
            result.message = "配置文件为空"
        end
    else
        result.message = "配置文件不存在"
    end
    
    http.write_json(result)
end

-- 下载OpenVPN配置文件
function download_openvpn_config()
    local filename = get_openvpn_config_path()
    
    if sys.call("test -f " .. filename .. " 2>/dev/null") == 0 then
        local content = sys.exec("cat " .. filename .. " 2>/dev/null")
        
        http.header('Content-Type', 'text/plain')
        http.header('Content-Disposition', 'attachment; filename="openvpn-config.txt"')
        http.header('Content-Length', tostring(#content))
        
        http.write(content)
    else
        http.status(404, "File not found")
        http.write("配置文件不存在")
    end
end

-- 获取配置节详情 (AJAX接口)
function get_config_section()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    local section_name = http.formvalue("section")
    
    if not section_name or section_name == "" then
        result.message = "未指定配置节名称"
        http.write_json(result)
        return
    end
    
    local config_lines = {}
    
    local uci_output = sys.exec("uci -q show openvpn." .. section_name .. " 2>/dev/null")
    if uci_output and uci_output ~= "" then
        for line in uci_output:gmatch("[^\r\n]+") do
            table.insert(config_lines, util.trim(line))
        end
        
        result.data = {
            section_name = section_name,
            config_lines = config_lines
        }
        result.success = true
    else
        result.message = "配置节不存在或为空"
    end
    
    http.write_json(result)
end

-- 保存OpenVPN配置 (AJAX接口)
function save_openvpn_config()
    local result = {
        success = false,
        message = "",
        redirect_url = nil
    }
    
    local config_content = http.formvalue("config")
    
    if not config_content or config_content == "" then
        result.message = "配置内容为空"
        http.write_json(result)
        return
    end
    
    if not config_content:match("config openvpn") then
        result.message = "配置必须包含config openvpn实例"
        http.write_json(result)
        return
    end
    
    local config_path = get_openvpn_config_path()
    
    -- 备份原配置文件
    local backup_file = config_path .. ".backup." .. os.time()
    local backup_cmd = string.format("cp %s %s 2>/dev/null", config_path, backup_file)
    sys.exec(backup_cmd)
    
    -- 保存新配置
    local temp_file = "/tmp/openvpn_config.tmp"
    
    local temp_fd = io.open(temp_file, "w")
    if temp_fd then
        temp_fd:write(config_content)
        temp_fd:close()
        
        local mv_cmd = string.format("mv %s %s", temp_file, config_path)
        local ret = sys.call(mv_cmd)
        
        if ret == 0 then
            result.success = true
            result.message = "配置保存成功"
        else
            result.message = "配置保存失败"
        end
    else
        result.message = "无法写入临时文件"
    end
    
    http.write_json(result)
end

-- 应用OpenVPN配置 (保存并重启服务) (AJAX接口)
function apply_openvpn_config()
    local result = {
        success = false,
        message = "",
        redirect_url = luci.dispatcher.build_url("admin/vpn/openvpn-admin/status")
    }
    
    local config_content = http.formvalue("config")
    
    if not config_content or config_content == "" then
        result.message = "配置内容为空"
        http.write_json(result)
        return
    end
    
    if not config_content:match("config openvpn") then
        result.message = "配置必须包含config openvpn实例"
        http.write_json(result)
        return
    end
    
    local config_path = get_openvpn_config_path()
    
    -- 备份原配置文件
    local backup_file = config_path .. ".backup." .. os.time()
    local backup_cmd = string.format("cp %s %s 2>/dev/null", config_path, backup_file)
    sys.exec(backup_cmd)
    
    -- 保存新配置
    local temp_file = "/tmp/openvpn_config.tmp"
    
    local temp_fd = io.open(temp_file, "w")
    if temp_fd then
        temp_fd:write(config_content)
        temp_fd:close()
        
        local mv_cmd = string.format("mv %s %s", temp_file, config_path)
        local ret = sys.call(mv_cmd)
        
        if ret == 0 then
            -- 应用配置
            local apply_cmd = "uci commit openvpn 2>/dev/null"
            local apply_ret = sys.call(apply_cmd)
            
            if apply_ret == 0 then
                -- 重启OpenVPN服务
                local restart_cmd = "/etc/init.d/openvpn restart 2>/dev/null"
                local restart_ret = sys.call(restart_cmd)
                
                if restart_ret == 0 then
                    result.success = true
                    result.message = "配置应用成功，OpenVPN服务已重启"
                else
                    result.message = "配置保存成功，但OpenVPN服务重启失败"
                    result.success = true
                end
            else
                result.message = "配置保存成功，但应用配置失败"
                result.success = true
            end
        else
            result.message = "配置保存失败"
        end
    else
        result.message = "无法写入临时文件"
    end
    
    http.write_json(result)
end

-- 生成客户端配置和证书 (AJAX接口)
function generate_client_config()
    local result = {
        success = false,
        message = "",
        filename = "",
        download_url = ""
    }
    
    local client_name = http.formvalue("client_name")
    local filename = http.formvalue("filename")
    
    if not client_name or client_name == "" then
        result.message = "客户端名称不能为空"
        http.write_json(result)
        return
    end
    
    if not client_name:match("^[%w_%-]+$") then
        result.message = "客户端名称格式不正确，只允许字母、数字、下划线、短横线"
        http.write_json(result)
        return
    end
    
    if filename and filename ~= "" then
        if not filename:match("^[%w_%-%.]+$") then
            result.message = "文件名格式不正确"
            http.write_json(result)
            return
        end
        if not filename:lower():match("%.ovpn$") then
            filename = filename .. ".ovpn"
        end
    else
        filename = client_name .. ".ovpn"
    end
    
    -- 创建临时目录（使用配置的临时目录）
    local config = get_admin_config()
    local temp_dir = config.temp_dir or "/tmp/openvpn-admin"
    sys.exec("mkdir -p " .. temp_dir .. " 2>/dev/null")
    
    -- 设置输出文件路径
    local output_file = temp_dir .. "/" .. filename
    
    -- 检查并生成客户端证书和配置
    local script_path = config.generate_client_script or "/etc/openvpn/generate-client.sh"
    
    -- 如果脚本不存在，创建它
    if sys.call("test -f " .. script_path .. " 2>/dev/null") ~= 0 then
        local cert_paths = get_cert_paths()
        local instance = get_openvpn_instance()
        
        local script_content = [[
#!/bin/sh
# OpenVPN客户端证书生成和配置文件生成脚本
# 参考genovpn.sh的原理，但不修改原文件

# 读取openvpn-admin配置
if [ -f /etc/config/openvpn-admin ]; then
    # 从配置文件中读取相关路径
    EASYRSA_DIR=$(uci -q get openvpn-admin.@settings[0].easyrsa_dir 2>/dev/null || echo "/etc/easy-rsa")
    EASYRSA_PKI=$(uci -q get openvpn-admin.@settings[0].easyrsa_pki 2>/dev/null || echo "/etc/easy-rsa/pki")
    OPENVPN_PKI=$(uci -q get openvpn-admin.@settings[0].openvpn_pki 2>/dev/null || echo "/etc/openvpn/pki")
    OPENVPN_INSTANCE=$(uci -q get openvpn-admin.@settings[0].openvpn_instance 2>/dev/null || echo "myvpn")
else
    # 默认值
    EASYRSA_DIR="/etc/easy-rsa"
    EASYRSA_PKI="$EASYRSA_DIR/pki"
    OPENVPN_PKI="/etc/openvpn/pki"
    OPENVPN_INSTANCE="myvpn"
fi

EASYRSA_VARS="$EASYRSA_DIR/vars-server"
TEMP_DIR="/tmp/openvpn-client"

# 参数检查
if [ -z "$1" ]; then
    echo "错误: 请指定客户端名称"
    exit 1
fi

CLIENT_NAME="$1"
OUTPUT_FILE="${2:-/tmp/$CLIENT_NAME.ovpn}"

# 创建临时目录
mkdir -p "$TEMP_DIR"

# 获取服务器配置 - 使用配置中的实例名称
DDNS=$(uci get openvpn.$OPENVPN_INSTANCE.ddns 2>/dev/null || echo "")
PORT=$(uci get openvpn.$OPENVPN_INSTANCE.port 2>/dev/null || echo "1194")
PROTO=$(uci get openvpn.$OPENVPN_INSTANCE.proto 2>/dev/null || echo "udp")

# 如果获取不到DDNS，尝试获取WAN IP
if [ -z "$DDNS" ] || [ "$DDNS" = "exmple.com" ]; then
    DDNS=$(uci get network.wan.ipaddr 2>/dev/null || echo "")
    if [ -z "$DDNS" ]; then
        DDNS=$(ip addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
fi

# 检查证书是否存在
check_client_cert() {
    local client_name="$1"
    
    # 检查是否已存在客户端证书
    if [ -f "$EASYRSA_PKI/issued/$client_name.crt" ] && \
       [ -f "$EASYRSA_PKI/private/$client_name.key" ]; then
        echo "客户端证书已存在: $client_name"
        return 0
    fi
    
    echo "客户端证书不存在: $client_name"
    return 1
}

# 生成客户端证书
generate_client_cert() {
    local client_name="$1"
    
    echo "正在生成客户端证书: $client_name"
    
    # 设置环境变量
    export EASYRSA_PKI="$EASYRSA_PKI"
    export EASYRSA_VARS_FILE="$EASYRSA_VARS"
    export EASYRSA_BATCH="1"
    
    # 切换到EasyRSA目录
    cd "$EASYRSA_DIR" || exit 1
    
    # 生成客户端证书（非交互模式）
    echo "正在生成证书..."
    if ! easyrsa build-client-full "$client_name" nopass >/dev/null 2>&1; then
        # 如果失败，尝试初始化PKI
        echo "初始化PKI并生成证书..."
        easyrsa init-pki
        easyrsa build-ca nopass
        easyrsa build-client-full "$client_name" nopass
    fi
    
    # 复制证书到OpenVPN目录
    mkdir -p "$OPENVPN_PKI"
    cp "$EASYRSA_PKI/ca.crt" "$OPENVPN_PKI/"
    cp "$EASYRSA_PKI/issued/$client_name.crt" "$OPENVPN_PKI/"
    cp "$EASYRSA_PKI/private/$client_name.key" "$OPENVPN_PKI/"
    
    echo "客户端证书生成完成: $client_name"
}

# 提取纯PEM格式证书（关键修复）
extract_pem_cert() {
    local cert_file="$1"
    
    if [ ! -f "$cert_file" ]; then
        echo "# 证书文件不存在"
        return 1
    fi
    
    # 提取BEGIN CERTIFICATE到END CERTIFICATE之间的内容
    # 使用sed提取纯PEM格式
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$cert_file"
}

# 提取纯PEM格式密钥
extract_pem_key() {
    local key_file="$1"
    
    if [ ! -f "$key_file" ]; then
        echo "# 密钥文件不存在"
        return 1
    fi
    
    # 提取BEGIN PRIVATE KEY到END PRIVATE KEY之间的内容
    sed -n '/-----BEGIN.*PRIVATE KEY-----/,/-----END.*PRIVATE KEY-----/p' "$key_file"
}

# 生成.ovpn配置文件（修复后）
generate_ovpn_config() {
    local client_name="$1"
    local output_file="$2"
    
    echo "正在生成配置文件: $output_file"
    
    # 创建配置文件
    cat > "$output_file" <<EOF
##############################################
# OpenVPN 客户端配置文件
# 生成时间: $(date)
# 客户端: $CLIENT_NAME
# 服务器: $DDNS:$PORT
##############################################

client
dev tun
proto $PROTO
remote $DDNS $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3

# 加密设置
cipher AES-256-GCM
auth SHA256

# TLS设置
remote-cert-tls server
key-direction 1

EOF

    # 添加CA证书 - 使用纯PEM格式
    echo "<ca>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/ca.crt" ]; then
        extract_pem_cert "$OPENVPN_PKI/ca.crt" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/ca.crt" ]; then
        extract_pem_cert "$EASYRSA_PKI/ca.crt" >> "$output_file"
    else
        echo "# CA证书不存在" >> "$output_file"
    fi
    echo "</ca>" >> "$output_file"

    # 添加客户端证书 - 使用纯PEM格式（关键修复）
    echo "<cert>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/$client_name.crt" ]; then
        extract_pem_cert "$OPENVPN_PKI/$client_name.crt" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/issued/$client_name.crt" ]; then
        extract_pem_cert "$EASYRSA_PKI/issued/$client_name.crt" >> "$output_file"
    else
        echo "# 客户端证书不存在" >> "$output_file"
    fi
    echo "</cert>" >> "$output_file"

    # 添加客户端密钥 - 使用纯PEM格式
    echo "<key>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/$client_name.key" ]; then
        extract_pem_key "$OPENVPN_PKI/$client_name.key" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/private/$client_name.key" ]; then
        extract_pem_key "$EASYRSA_PKI/private/$client_name.key" >> "$output_file"
    else
        echo "# 客户端密钥不存在" >> "$output_file"
    fi
    echo "</key>" >> "$output_file"

    # 添加附加配置（如果存在）
    if [ -f "/etc/openvpn-addon.conf" ]; then
        cat "/etc/openvpn-addon.conf" >> "$output_file"
    fi
    
    echo "配置文件生成完成: $output_file"
}

# 主执行流程
main() {
    echo "开始生成OpenVPN客户端配置"
    echo "客户端名称: $CLIENT_NAME"
    echo "输出文件: $OUTPUT_FILE"
    echo "服务器地址: $DDNS:$PORT ($PROTO)"
    echo "使用实例: $OPENVPN_INSTANCE"
    echo "EasyRSA目录: $EASYRSA_DIR"
    echo "PKI目录: $EASYRSA_PKI"
    
    # 检查证书是否存在
    if ! check_client_cert "$CLIENT_NAME"; then
        echo "证书不存在，开始生成..."
        if ! generate_client_cert "$CLIENT_NAME"; then
            echo "错误: 证书生成失败"
            exit 1
        fi
    fi
    
    # 生成.ovpn配置文件
    generate_ovpn_config "$CLIENT_NAME" "$OUTPUT_FILE"
    
    # 验证文件是否生成成功
    if [ -f "$OUTPUT_FILE" ]; then
        echo "生成成功！"
        echo "文件位置: $OUTPUT_FILE"
        echo "文件大小: $(du -h "$OUTPUT_FILE" | cut -f1)"
    else
        echo "错误: 文件生成失败"
        exit 1
    fi
}

# 执行主函数
main
]]
        
        local script_fd = io.open(script_path, "w")
        if script_fd then
            script_fd:write(script_content)
            script_fd:close()
            sys.exec("chmod +x " .. script_path .. " 2>/dev/null")
        else
            result.message = "无法创建生成脚本"
            http.write_json(result)
            return
        end
    end
    
    -- 执行生成脚本
    local cmd = string.format("%s '%s' '%s' 2>&1", script_path, client_name, output_file)
    local output = sys.exec(cmd)
    
    if sys.call("test -f " .. output_file .. " 2>/dev/null") == 0 then
        result.success = true
        result.message = "客户端配置生成成功"
        result.filename = filename
        result.download_url = luci.dispatcher.build_url("admin/vpn/openvpn-admin/download_client_config") .. "?filename=" .. filename .. "&client=" .. client_name
        
        nixio.syslog("info", "OpenVPN客户端配置生成成功: " .. client_name .. " -> " .. filename)
    else
        result.message = "配置文件生成失败: " .. (output or "未知错误")
    end
    
    http.write_json(result)
end

-- 重置所有证书 (AJAX接口)
function reset_all_certificates()
    local result = {
        success = false,
        message = "",
        debug_info = {}
    }
    
    local config = get_admin_config()
    local renew_script = config.renew_cert_script or "/etc/openvpn/renewcert.sh"
    
    local script_check = {}
    
    local file_exists = sys.call("test -f " .. renew_script .. " 2>/dev/null")
    table.insert(script_check, "file_exists: " .. (file_exists == 0 and "true" or "false"))
    
    if file_exists ~= 0 then
        result.message = "重置脚本不存在: " .. renew_script
        result.debug_info = script_check
        http.write_json(result)
        return
    end
    
    local file_perm = sys.exec("ls -la " .. renew_script .. " 2>/dev/null | head -1")
    table.insert(script_check, "file_permission: " .. (file_perm or "未知"))
    
    if file_perm and not file_perm:match("x") then
        local chmod_result = sys.call("chmod +x " .. renew_script .. " 2>/dev/null")
        table.insert(script_check, "chmod_result: " .. tostring(chmod_result))
        
        if chmod_result ~= 0 then
            result.message = "脚本没有执行权限，且无法添加权限"
            result.debug_info = script_check
            http.write_json(result)
            return
        end
    end
    
    local script_first_line = sys.exec("head -1 " .. renew_script .. " 2>/dev/null")
    table.insert(script_check, "script_first_line: " .. (script_first_line or "空"))
    
    if not script_first_line or not script_first_line:match("^#!") then
        result.message = "脚本文件格式不正确，不是有效的shell脚本"
        result.debug_info = script_check
        http.write_json(result)
        return
    end
    
    local start_time = os.time()
    table.insert(script_check, "start_time: " .. os.date("%Y-%m-%d %H:%M:%S", start_time))
    
    local log_file = "/tmp/renewcert.log"
    local cmd = renew_script .. " > " .. log_file .. " 2>&1 &"
    table.insert(script_check, "command: " .. cmd)
    
    sys.exec("echo '=== 证书重置开始 " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===' > " .. log_file .. " 2>/dev/null")
    
    local ret = sys.call(cmd)
    table.insert(script_check, "return_code: " .. tostring(ret))
    
    sys.exec("sleep 1")
    
    local pid = sys.exec("pgrep -f 'renewcert.sh' 2>/dev/null | head -1")
    table.insert(script_check, "pid_after_1s: " .. (pid or "未找到"))
    
    if pid and pid ~= "" then
        result.success = true
        result.message = "证书重置脚本已启动成功 (PID: " .. util.trim(pid) .. ")"
        
        nixio.syslog("info", "OpenVPN证书重置脚本已启动，PID: " .. util.trim(pid))
        
        local status_content = "证书重置开始时间: " .. os.date("%Y-%m-%d %H:%M:%S", start_time) .. "\n"
        status_content = status_content .. "进程PID: " .. util.trim(pid) .. "\n"
        status_content = status_content .. "日志文件: " .. log_file .. "\n"
        
        local status_fd = io.open("/tmp/openvpn_status.log", "w")
        if status_fd then
            status_fd:write(status_content)
            status_fd:close()
        end
        
    elseif ret == 0 then
        result.success = true
        result.message = "证书重置脚本已执行"
        
        local log_content = sys.exec("tail -10 " .. log_file .. " 2>/dev/null")
        if log_content and log_content:match("error") then
            result.message = "脚本已执行，但可能存在错误，请检查日志"
            table.insert(script_check, "log_has_error: true")
        end
        
        nixio.syslog("info", "OpenVPN证书重置脚本已执行")
    else
        result.message = "证书重置脚本启动失败"
        table.insert(script_check, "execution_failed: true")
        
        local error_output = sys.exec(renew_script .. " 2>&1 | head -5")
        if error_output and error_output ~= "" then
            table.insert(script_check, "error_output: " .. error_output)
        end
        
        nixio.syslog("err", "OpenVPN证书重置脚本启动失败，返回码: " .. tostring(ret))
    end
    
    result.debug_info = script_check
    http.write_json(result)
end

-- 下载客户端配置文件 (AJAX接口)
function download_client_config()
    local result = {
        success = false,
        message = "",
        content = "",
        filename = ""
    }
    
    local client_name = http.formvalue("client")
    local filename = http.formvalue("filename") or (client_name and client_name .. ".ovpn")
    
    if not client_name or client_name == "" then
        result.message = "客户端名称不能为空"
        http.write_json(result)
        return
    end
    
    local config = get_admin_config()
    local temp_dir = config.temp_dir or "/tmp/openvpn-admin"
    local temp_file = temp_dir .. "/" .. (filename or client_name .. ".ovpn")
    local script_path = config.generate_client_script or "/etc/openvpn/generate-client.sh"
    
    if sys.call("test -f " .. script_path .. " 2>/dev/null") == 0 then
        -- 确保临时目录存在
        sys.exec("mkdir -p " .. temp_dir .. " 2>/dev/null")
        
        local cmd = script_path .. " '" .. client_name .. "' '" .. temp_file .. "' 2>&1"
        local output = sys.exec(cmd)
        
        if sys.call("test -f " .. temp_file .. " 2>/dev/null") == 0 then
            local content = sys.exec("cat " .. temp_file .. " 2>/dev/null")
            
            http.header('Content-Type', 'application/x-openvpn-profile')
            http.header('Content-Disposition', 'attachment; filename="' .. filename .. '"')
            http.header('Content-Length', tostring(#content))
            
            http.write(content)
            
            -- 清理临时文件
            sys.exec("rm -f " .. temp_file .. " 2>/dev/null")
            return
        else
            result.message = "配置文件生成失败: " .. output
        end
    else
        result.message = "生成脚本不存在"
    end
    
    http.write_json(result)
end

-- 获取OpenVPN UCI配置（AJAX接口）
function get_openvpn_uci_config()
    local result = {
        success = false,
        data = {},
        message = ""
    }
    
    local instance = get_openvpn_instance()
    
    if not instance or instance == "" then
        result.message = "OpenVPN实例名称未配置"
        http.write_json(result)
        return
    end
    
    -- 检查实例是否存在
    local exists = uci:get("openvpn", instance)
    if not exists then
        result.message = "OpenVPN实例不存在: " .. instance
        http.write_json(result)
        return
    end
    
    -- 获取所有可配置的选项
    local config_options = {
        -- 基本设置
        "enabled", "proto", "port", "ddns", "dev", "topology", "server",
        -- 证书路径
        "ca", "dh", "cert", "key",
        -- 高级设置
        "persist_key", "persist_tun", "user", "group", "max_clients", 
        "keepalive", "verb", "status", "log", "compress",
        -- management接口
        "management", "management_forget_disconnect",
        -- 黑名单脚本
        "client_connect", "script_security",
        -- IPv6地址
        "local"
    }
    
    -- 初始化配置数据
    local config_data = {}
    
    for _, option in ipairs(config_options) do
        local value = uci:get("openvpn", instance, option)
        if value then
            if option == "enabled" or option == "persist_key" or option == "persist_tun" or 
               option == "management_forget_disconnect" then
                config_data[option] = (value == "1")
            else
                config_data[option] = value
            end
        else
            -- 设置默认值
            if option == "enabled" then
                config_data[option] = false  -- 默认关闭
            elseif option == "proto" then
                config_data[option] = "udp"
            elseif option == "port" then
                config_data[option] = "1194"
            elseif option == "ddns" then
                config_data[option] = ""
            elseif option == "dev" then
                config_data[option] = "tun"
            elseif option == "topology" then
                config_data[option] = "subnet"
            elseif option == "server" then
                config_data[option] = "10.8.0.0 255.255.255.0"
            elseif option == "compress" then
                config_data[option] = ""
            elseif option == "max_clients" then
                config_data[option] = "10"
            elseif option == "keepalive" then
                config_data[option] = "10 120"
            elseif option == "verb" then
                config_data[option] = "3"
            elseif option == "user" then
                config_data[option] = "nobody"
            elseif option == "group" then
                config_data[option] = "nogroup"
            elseif option == "status" then
                config_data[option] = "/var/log/openvpn_status.log"
            elseif option == "log" then
                config_data[option] = "/tmp/openvpn.log"
            elseif option == "persist_key" then
                config_data[option] = true
            elseif option == "persist_tun" then
                config_data[option] = true
            elseif option == "management_forget_disconnect" then
                config_data[option] = true
            else
                config_data[option] = ""
            end
        end
    end
    
    -- 获取push列表 - 正确的方式
    local push_options = {}
    local all_config = uci:get_all("openvpn", instance)
    if all_config then
        for key, value in pairs(all_config) do
            if key:match("^push") and type(value) == "string" and value ~= "" then
                table.insert(push_options, value)
            elseif key == "push" and type(value) == "table" then
                -- 如果是列表格式
                for _, v in ipairs(value) do
                    if v and v ~= "" then
                        table.insert(push_options, v)
                    end
                end
            end
        end
    end
    
    config_data.push = push_options
    
    -- 检查management接口是否启用 - 修改：支持Unix Socket路径
local management_value = uci:get("openvpn", instance, "management")
config_data.enable_management = management_value and management_value ~= ""

-- 处理management值，提取纯路径部分供前端显示
if config_data.enable_management and management_value then
    -- 检查是否为Unix Socket格式（以/开头）
    if management_value:match("^/") then
        -- 提取纯路径部分（去掉后面的 "unix" 关键字）
        local pure_path = management_value:match("^(/[^%s]+)")
        config_data.management_path = pure_path or management_value
        nixio.syslog("debug", "提取management路径: " .. tostring(config_data.management_path))
    else
        -- 如果不是Unix Socket格式，可能是旧的TCP配置，使用默认值
        config_data.management_path = "/var/run/openvpn.sock"
        nixio.syslog("warning", "management配置不是Unix Socket格式，使用默认路径")
    end
else
    -- 未启用时也设置默认路径
    config_data.management_path = "/var/run/openvpn.sock"
end
    
    -- 检查黑名单是否启用
    local client_connect_value = uci:get("openvpn", instance, "client_connect")
    config_data.enable_blacklist = client_connect_value and client_connect_value ~= ""
    
    -- 检查IPv6是否启用
    local local_value = uci:get("openvpn", instance, "local")
    config_data.enable_ipv6 = local_value and local_value ~= ""
    
    -- 如果黑名单启用，确保script_security有值
    if config_data.enable_blacklist and (not config_data.script_security or config_data.script_security == "") then
        config_data.script_security = "3"
    end
    
    result.data = config_data
    result.success = true
    
    http.write_json(result)
end

-- 保存OpenVPN UCI配置（AJAX接口）- 已添加防火墙端口同步功能
function save_openvpn_uci_config()
    local result = {
        success = false,
        message = ""
    }
    
    local instance = get_openvpn_instance()
    
    if not instance or instance == "" then
        result.message = "OpenVPN实例名称未配置"
        http.write_json(result)
        return
    end
    
    -- 保存原有端口，用于比较是否需要更新防火墙
    local old_port = nil
    local old_proto = nil
    local exists = uci:get("openvpn", instance)
    if exists then
        old_port = uci:get("openvpn", instance, "port")
        old_proto = uci:get("openvpn", instance, "proto")
    end
    
    -- 检查实例是否存在，如果不存在则创建
    local exists = uci:get("openvpn", instance)
    if not exists then
        local ok, err = pcall(function()
            uci:section("openvpn", "openvpn", instance, {})
        end)
        if not ok then
            result.message = "创建实例失败: " .. tostring(err)
            http.write_json(result)
            return
        end
    end
    
    -- 处理基本配置项
    local config_fields = {
        "enabled", "proto", "port", "ddns", "dev", "topology", "server",
        "ca", "dh", "cert", "key", "persist_key", "persist_tun", "user",
        "group", "max_clients", "keepalive", "verb", "status", "log",
        "compress"
    }
    
    for _, field in ipairs(config_fields) do
        local value = http.formvalue(field)
        if value ~= nil then
            if field == "enabled" or field == "persist_key" or field == "persist_tun" then
                value = (value == "1" or value == "true" or value == "on") and "1" or "0"
            end
            local ok, err = pcall(function()
                uci:set("openvpn", instance, field, value)
            end)
            if not ok then
                result.message = "设置字段 " .. field .. " 失败: " .. tostring(err)
                http.write_json(result)
                return
            end
        end
    end
    
    -- 处理IPv6地址
    local enable_ipv6 = http.formvalue("enable_ipv6")
    local local_address = http.formvalue("local")
    if enable_ipv6 and enable_ipv6 == "1" and local_address and local_address ~= "" then
        local ok, err = pcall(function()
            uci:set("openvpn", instance, "local", local_address)
        end)
        if not ok then
            result.message = "设置IPv6地址失败: " .. tostring(err)
            http.write_json(result)
            return
        end
    else
        -- 禁用IPv6时删除local选项
        local ok, err = pcall(function()
            uci:delete("openvpn", instance, "local")
        end)
        if not ok then
            -- 如果删除失败，可能该选项不存在，这不算错误
        end
    end
    
    -- 处理push列表（先清除所有现有的push）
    local ok, all_config = pcall(function()
        return uci:get_all("openvpn", instance)
    end)
    
    if ok and all_config then
        for key, _ in pairs(all_config) do
            if key:match("^push") then
                local ok, err = pcall(function()
                    uci:delete("openvpn", instance, key)
                end)
                if not ok then
                    result.message = "删除push配置 " .. key .. " 失败: " .. tostring(err)
                    http.write_json(result)
                    return
                end
            end
        end
    end
    
    -- 添加新的push列表 - 修复push配置保存问题
    -- 收集所有push配置
    local push_list = {}
    local push_index = 0
    while true do
        local push_value_raw = http.formvalue("push_" .. push_index)
        if not push_value_raw or push_value_raw == "" then
            break
        end
        
        -- 从原始值中提取实际的push内容
        -- 原始值格式: list push 'route 192.168.100.0 255.255.255.0'
        -- 我们需要提取: 'route 192.168.100.0 255.255.255.0'
        local push_content = push_value_raw:match("list push%s+'([^']+)'")
        if not push_content then
            -- 尝试另一种匹配方式
            push_content = push_value_raw:match("list push%s+\"([^\"]+)\"")
        end
        
        if not push_content then
            -- 如果没有匹配到引号内容，尝试匹配整个字符串（去除非引号部分）
            -- 移除开头的'list push'和空格
            push_content = push_value_raw:gsub("^list push%s+", "")
            -- 移除可能的引号
            push_content = push_content:gsub("^['\"]", ""):gsub("['\"]$", "")
        end
        
        if push_content and push_content ~= "" then
            table.insert(push_list, push_content)
        else
            -- 如果无法解析，使用原始值（但移除list push前缀）
            push_content = push_value_raw:gsub("^list push%s+", "")
            if push_content and push_content ~= "" then
                table.insert(push_list, push_content)
            end
        end
        
        push_index = push_index + 1
    end
    
    -- 如果有push配置，添加到UCI配置中
    if #push_list > 0 then
        for i, push_content in ipairs(push_list) do
            local ok, err = pcall(function()
                -- 使用uci:add_list添加push配置项
                uci:set_list("openvpn", instance, "push", push_list)
            end)
            if not ok then
                result.message = "添加push配置失败: " .. tostring(err)
                http.write_json(result)
                return
            end
        end
    end
    
    -- 处理management接口 - 增加路径自动补全和目录检查
local enable_management = http.formvalue("enable_management")
if enable_management and enable_management == "1" then
    -- 获取用户输入的路径
    local management_path = http.formvalue("management_path") or "/var/run/openvpn.sock"
    
    -- 去除两端空格
    management_path = management_path:match("^%s*(.-)%s*$")
    
    if management_path and management_path ~= "" then
        -- 自动处理 unix 后缀
        local has_unix = management_path:match("%s+unix$") or management_path:match("^unix$")
        if not has_unix then
            management_path = management_path .. " unix"
        else
            -- 统一格式（纯路径 + 空格 + unix）
            local pure = management_path:match("^(.-)%s+unix$")
            if pure then
                pure = pure:match("^%s*(.-)%s*$")
                management_path = pure .. " unix"
            end
        end
        
        -- 提取纯路径用于目录检查
        local pure_path = management_path:match("^(.-)%s+unix$") or management_path
        pure_path = pure_path:match("^%s*(.-)%s*$")
        
        -- 检查父目录是否存在
        local dir = pure_path:match("^(.*/)[^/]*$")
        if dir then
            dir = dir:sub(1, -2)  -- 去掉末尾的 '/'
            if sys.call("test -d " .. dir .. " 2>/dev/null") ~= 0 then
                -- 尝试创建目录
                if sys.call("mkdir -p " .. dir .. " 2>/dev/null") ~= 0 then
                    result.message = "目录 " .. dir .. " 不存在且无法自动创建，请检查权限"
                    http.write_json(result)
                    return
                end
            end
        end
        
        -- 保存完整 management 值
        local ok, err = pcall(function()
            uci:set("openvpn", instance, "management", management_path)
            nixio.syslog("info", "设置management接口: " .. management_path)
        end)
        if not ok then
            result.message = "设置management接口失败: " .. tostring(err)
            http.write_json(result)
            return
        end
    end
    
    local management_forget = http.formvalue("management_forget_disconnect")
    if management_forget then
        local value = (management_forget == "1" or management_forget == "true" or management_forget == "on") and "1" or "0"
        local ok, err = pcall(function()
            uci:set("openvpn", instance, "management_forget_disconnect", value)
        end)
        if not ok then
            result.message = "设置management_forget_disconnect失败: " .. tostring(err)
            http.write_json(result)
            return
        end
    else
        -- 默认启用
        local ok, err = pcall(function()
            uci:set("openvpn", instance, "management_forget_disconnect", "1")
        end)
        if not ok then
            result.message = "设置management_forget_disconnect默认值失败: " .. tostring(err)
            http.write_json(result)
            return
        end
    end
else
    -- 禁用时删除management和management_forget_disconnect
    pcall(function() uci:delete("openvpn", instance, "management") end)
    pcall(function() uci:delete("openvpn", instance, "management_forget_disconnect") end)
end
    
-- 处理黑名单
local enable_blacklist = http.formvalue("enable_blacklist")
if enable_blacklist and enable_blacklist == "1" then
    local client_connect = http.formvalue("client_connect") or "/etc/openvpn/client-connect-cn.sh"
    local script_security = http.formvalue("script_security") or "3"
    
    local ok1, err1 = pcall(function()
        uci:set("openvpn", instance, "client_connect", client_connect)
    end)
    local ok2, err2 = pcall(function()
        uci:set("openvpn", instance, "script_security", script_security)
    end)
    
    if not ok1 then
        result.message = "设置client_connect失败: " .. tostring(err1)
        http.write_json(result)
        return
    end
    if not ok2 then
        result.message = "设置script_security失败: " .. tostring(err2)
        http.write_json(result)
        return
    end
else
    -- 禁用时删除黑名单相关配置
    local ok1, err1 = pcall(function()
        uci:delete("openvpn", instance, "client_connect")
    end)
    local ok2, err2 = pcall(function()
        uci:delete("openvpn", instance, "script_security")
    end)
    
    if not ok1 then
        -- 如果删除失败，可能该选项不存在，这不算错误
    end
    if not ok2 then
        -- 如果删除失败，可能该选项不存在，这不算错误
    end
end
    
    -- 提交更改
    local save_ok, save_err = pcall(function()
        return uci:save("openvpn")
    end)
    
    if save_ok then
        local commit_ok, commit_err = pcall(function()
            return uci:commit("openvpn")
        end)
        
        if commit_ok then
            -- 获取新配置的端口
            local new_port = http.formvalue("port") or uci:get("openvpn", instance, "port") or old_port
            
            -- 检查IPv6是否启用
            local enable_ipv6 = http.formvalue("enable_ipv6")
            if enable_ipv6 and enable_ipv6 == "1" then
                -- 获取IPv6脚本配置
                local config = get_admin_config()
                
                if config.ipv6_script_enabled then
                    -- 运行IPv6脚本
                    local script_result = run_ipv6_script_if_enabled()
                    if script_result == false then
                        result.message = result.message .. " (警告：IPv6脚本不存在)"
                    elseif script_result == true then
                        result.message = result.message .. " (IPv6脚本已执行)"
                    end
                    
                    -- 更新IPv6定时任务
                    update_ipv6_cron_job()
                end
            else
                -- 如果禁用了IPv6，也更新定时任务（会移除IPv6定时任务）
                update_ipv6_cron_job()
            end
            
            -- 如果端口发生变化，或者之前没有端口但现在有了，则更新防火墙规则
            if new_port then
                if old_port and new_port ~= old_port then
                    -- 端口变化，更新防火墙规则
                    local firewall_result = update_firewall_port(old_port, new_port)
                    if firewall_result then
                        result.message = "配置保存成功，OpenVPN服务已重启，防火墙端口已从 " .. old_port .. " 更新为 " .. new_port
                    else
                        result.message = "配置保存成功，OpenVPN服务已重启，但防火墙端口更新失败"
                    end
                elseif not old_port and new_port then
                    -- 之前没有端口配置，现在有端口，添加防火墙规则
                    local firewall_result = add_firewall_port(new_port)
                    if firewall_result then
                        result.message = "配置保存成功，OpenVPN服务已重启，防火墙已添加端口 " .. new_port .. " 规则"
                    else
                        result.message = "配置保存成功，OpenVPN服务已重启，但防火墙规则添加失败"
                    end
                else
                    -- 端口未变化，检查防火墙规则是否存在
                    local rule_exists, rule_section = check_firewall_rule()
                    if not rule_exists then
                        -- 防火墙规则不存在，创建它
                        local firewall_result = add_firewall_port(new_port)
                        if firewall_result then
                            result.message = "配置保存成功，OpenVPN服务已重启，防火墙已添加端口 " .. new_port .. " 规则"
                        else
                            result.message = "配置保存成功，OpenVPN服务已重启，但防火墙规则创建失败"
                        end
                    else
                        result.message = "配置保存成功，OpenVPN服务已重启"
                    end
                end
            else
                result.message = "配置保存成功，OpenVPN服务已重启（未指定端口）"
            end
            
            -- 重启OpenVPN服务
            local ret = sys.call("/etc/init.d/openvpn restart >/dev/null 2>&1")
            
            if ret ~= 0 then
                result.message = result.message .. "，但OpenVPN服务重启失败，请手动重启"
            end
            
            result.success = true
        else
            result.message = "提交配置失败: " .. tostring(commit_err)
        end
    else
        result.message = "保存配置失败: " .. tostring(save_err)
    end
    
    http.write_json(result)
end

-- 工具函数：格式化字节数
function format_bytes(bytes)
    if not bytes or bytes == 0 then return "0 B" end
    local units = {"B", "KB", "MB", "GB"}
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format("%.2f %s", bytes, units[i])
end

-- 计算数据总计（接收+发送）
function calculate_total_data(bytes_received, bytes_sent)
    if not bytes_received then bytes_received = 0 end
    if not bytes_sent then bytes_sent = 0 end
    return format_bytes(bytes_received + bytes_sent)
end

-- 新增：手动触发Hotplug（修复版 - 不使用nohup）
function action_manual_trigger_hotplug()
    local result = {
        success = false,
        pid = "",
        message = ""
    }
    
    local monitor_interface = http.formvalue("interface")
    
    if not monitor_interface or monitor_interface == "" then
        result.message = "监控接口不能为空"
        http.write_json(result)
        return
    end
    
    local config = get_admin_config()
    
    -- 检查Hotplug脚本是否存在
    local script_path = config.hotplug_script_path or "/etc/openvpn/openvpn_hotplug.sh"
    
    if sys.call("test -f " .. script_path .. " 2>/dev/null") ~= 0 then
        result.message = "Hotplug脚本不存在: " .. script_path
        http.write_json(result)
        return
    end
    
    -- 检查脚本是否有执行权限
    if sys.call("test -x " .. script_path .. " 2>/dev/null") ~= 0 then
        sys.exec("chmod +x " .. script_path .. " 2>/dev/null")
    end
    
    -- 清理旧日志文件
    sys.exec("echo '' > /tmp/openvpn_hotplug.log 2>/dev/null")
    
    -- 记录开始时间
    local start_time = os.time()
    sys.exec("echo '=== 手动触发Hotplug开始 " .. os.date("%Y-%m-%d %H:%M:%S", start_time) .. " ===' > /tmp/openvpn_hotplug.log 2>/dev/null")
    
    -- 修改：不使用nohup，直接用 & 后台运行，并将输出重定向到日志文件
    -- 使用 sh -c 来执行命令
    local cmd = string.format("sh -c '%s ifup %s >> /tmp/openvpn_hotplug.log 2>&1' &", script_path, monitor_interface)
    
    nixio.syslog("info", "执行命令: " .. cmd)
    
    local ret = sys.call(cmd)
    
    -- 等待脚本启动
    sys.exec("sleep 0.5")
    
    -- 获取进程PID
    local pid = sys.exec("pgrep -f 'openvpn_hotplug.*ifup' 2>/dev/null | head -1")
    
    if pid and pid ~= "" then
        result.success = true
        result.pid = util.trim(pid)
        result.message = "Hotplug脚本已启动"
        
        -- 记录PID到日志
        sys.exec(string.format("echo '进程PID: %s' >> /tmp/openvpn_hotplug.log 2>/dev/null", result.pid))
        
        nixio.syslog("info", "手动触发Hotplug脚本，PID: " .. result.pid .. ", 接口: " .. monitor_interface)
    elseif ret == 0 then
        result.success = true
        result.message = "Hotplug脚本已启动，但无法获取PID"
        nixio.syslog("info", "手动触发Hotplug脚本，接口: " .. monitor_interface)
    else
        result.message = "启动Hotplug脚本失败"
        nixio.syslog("err", "手动触发Hotplug脚本失败")
    end
    
    http.write_json(result)
end

-- 新增：获取Hotplug日志
-- 新增：获取Hotplug日志 - 【修改】增强兼容性，确保在ImmortalWrt上也能正确返回
function action_get_hotplug_log()
    local result = {
        success = false,
        log_exists = false,
        log_content = "",
        log_size = 0,
        start_time = os.time(),
        message = ""
    }
    
    local log_file = "/tmp/openvpn_hotplug.log"
    
    -- 检查日志文件是否存在
    if sys.call("test -f " .. log_file .. " 2>/dev/null") == 0 then
        result.log_exists = true
        
        -- 获取文件大小 - 使用更兼容的方式
        local size_cmd = "wc -c < " .. log_file .. " 2>/dev/null | tr -d ' '"
        local size_output = sys.exec(size_cmd)
        result.log_size = tonumber(size_output) or 0
        
        -- 读取日志内容（限制大小，避免内存问题）
        if result.log_size > 0 then
            -- 如果文件太大，只读取最后100KB
            if result.log_size > 102400 then
                -- 【修改】使用更兼容的命令，避免编码问题
                result.log_content = sys.exec("tail -c 102400 " .. log_file .. " 2>/dev/null | tr -d '\\r'")
            else
                -- 【修改】读取整个文件，并清理回车符
                result.log_content = sys.exec("cat " .. log_file .. " 2>/dev/null | tr -d '\\r'")
            end
            
            -- 【新增】确保内容是字符串类型
            if type(result.log_content) ~= "string" then
                result.log_content = tostring(result.log_content)
            end
            
            -- 【新增】如果内容为空但有大小，说明可能是二进制或编码问题
            if result.log_content == "" and result.log_size > 0 then
                -- 尝试以二进制方式读取
                local f = io.open(log_file, "rb")
                if f then
                    local content = f:read("*all")
                    f:close()
                    if content then
                        -- 过滤掉非ASCII字符，保留可读内容
                        local filtered = ""
                        for i = 1, #content do
                            local byte = string.byte(content, i)
                            if byte >= 32 and byte <= 126 or byte == 10 or byte == 13 then
                                filtered = filtered .. string.char(byte)
                            end
                        end
                        result.log_content = filtered
                    end
                end
            end
        end
        
        result.success = true
    else
        result.log_exists = false
        result.message = "日志文件不存在"
        result.success = true  -- 仍然返回成功，只是日志不存在
    end
    
    -- 【新增】设置明确的JSON响应头
    http.header("Content-Type", "application/json; charset=utf-8")
    
    -- 【修改】直接输出JSON，避免任何额外空白
    local json_str = require("luci.jsonc").stringify(result)
    http.write(json_str)
end