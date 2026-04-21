--[[
    LuCI OTA 升级插件 - 控制器 (Controller)
    
    功能特性：
    1. 动态菜单：检测更新后自动在菜单栏显示红点提醒。
    2. 进度追踪：支持固件刷写阶段及重启后插件恢复阶段的双重进度获取。
    3. 安全审计：读取配置冲突报告，供前端展示潜在的覆盖风险。
    4. 备份保护：提供一键预防性系统备份下载接口。
    5. 智能识别：自动分析用户手动安装的插件列表，实现 Safe-Flash 保护。
]]--

-- 注意：新版 LuCI 建议使用局部变量并返回 table 模式
local m = {}

function m.index()
    local fs = require "nixio.fs"
    
    -- --- 1. 动态菜单与红点逻辑 ---
    -- 检测是否存在新版本标志文件（可由后台定时 crontab 任务生成）
    local update_ready = fs.access("/tmp/ota_update_ready")
    local main_title = update_ready and _("OTA 升级 ●") or _("OTA 升级")

    -- 注册主入口 admin/system/ota
    entry({"admin", "system", "ota"}, alias("admin", "system", "ota", "client"), main_title, 60).dependent = true

    -- 注册子页面：升级中心 (index.htm)
    entry({"admin", "system", "ota", "client"}, template("ota/index"), _("固件升级"), 10).leaf = true
    -- 注册子页面：全局配置 (cbi/ota.lua)
    entry({"admin", "system", "ota", "config"}, cbi("ota"), _("设置"), 20).leaf = true

    -- --- 2. 接口映射 (AJAX API) ---
    -- 基础信息与更新检查
    entry({"admin", "system", "ota", "info"}, call("get_info")).leaf = true
    entry({"admin", "system", "ota", "check_update"}, call("get_remote_info")).leaf = true
    
    -- 升级执行控制与实时状态
    entry({"admin", "system", "ota", "start"}, call("start_upgrade")).leaf = true
    entry({"admin", "system", "ota", "state"}, call("get_state")).leaf = true
    entry({"admin", "system", "ota", "log"}, call("get_log")).leaf = true
    
    -- 配置审计报告：获取固件下载后的文件差异 (Diff)
    entry({"admin", "system", "ota", "audit_report"}, call("action_get_audit")).leaf = true
    
    -- 安全备份与重启后恢复状态
    entry({"admin", "system", "ota", "backup"}, call("action_backup")).leaf = true
    entry({"admin", "system", "ota", "restore_status"}, call("get_restore_status")).leaf = true
end

-- --- 3. 业务逻辑实现 ---

-- [核心功能] 获取配置审计详情
-- 逻辑：读取 ota.sh 在审计阶段生成的 /tmp/ota_audit_report.txt 文件
function m.action_get_audit()
    local fs = require "nixio.fs"
    local report_path = "/tmp/ota_audit_report.txt"
    
    if fs.access(report_path) then
        local content = fs.readfile(report_path)
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write(content)
    else
        -- 若文件不存在，返回 404，前端将忽略审计直接进入升级确认
        luci.http.status(404, "No Audit Report")
    end
end

-- 获取实时升级状态 (读取脚本生成的 /tmp/ota_state.json)
function m.get_state()
    local fs = require "nixio.fs"
    local data = fs.readfile("/tmp/ota_state.json")
    
    luci.http.prepare_content("application/json")
    if data and #data > 5 then 
        luci.http.write(data)
    else
        -- 默认空闲状态
        luci.http.write_json({state = "IDLE", msg = "等待操作", progress = 0})
    end
end

-- 获取重启后的插件恢复进度 (从持久化存储 /etc/config/ 读取)
-- 此文件由 uci-defaults 中的恢复脚本生成并实时更新
function m.get_restore_status()
    local fs = require "nixio.fs"
    local status_path = "/etc/config/ota_restore_status"
    
    luci.http.prepare_content("application/json")
    if fs.access(status_path) then
        local content = fs.readfile(status_path)
        luci.http.write(content)
    else
        -- 返回 404 或自定义空状态，告知前端当前没有正在进行的恢复任务
        luci.http.status(404, "No Active Restore Task")
    end
end

-- 读取升级过程中的实时控制台日志
function m.get_log()
    local fs = require "nixio.fs"
    local log_content = fs.readfile("/tmp/ota_build.log") or "等待日志输出..."
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(log_content)
end

-- 执行预防性系统备份
-- 使用 OpenWrt 标准 sysupgrade 命令生成备份包并提供下载流
function m.action_backup()
    local fs = require "nixio.fs"
    local util = require "luci.util"
    local backup_path = "/tmp/ota_backup.tar.gz"
    
    -- 静默生成备份
    os.execute(string.format("sysupgrade --create-backup %s >/dev/null 2>&1", backup_path))
    
    if fs.access(backup_path) then
        local board = util.exec("cat /tmp/sysinfo/board_name 2>/dev/null"):trim() or "openwrt"
        -- 设置下载头，文件名包含日期和硬件名
        luci.http.header("Content-Disposition", 'attachment; filename="backup-%s-%s.tar.gz"' % {
            os.date("%Y%m%d"), board
        })
        luci.http.prepare_content("application/x-targz")
        
        -- 流式读取文件防止内存溢出
        local f = io.open(backup_path, "r")
        if f then
            while true do
                local block = f:read(4096)
                if not block then break end
                luci.http.write(block)
            end
            f:close()
        end
        -- 下载完成后删除临时备份文件
        fs.unlink(backup_path)
    else
        luci.http.status(500, "Backup generation failed")
    end
end

-- 获取本地硬件 DNA 及当前版本信息
function m.get_info()
    local sys = require "luci.sys"
    local platform = sys.exec("uname -m") or "Unknown"
    local version = sys.exec("cat /etc/ota_version 2>/dev/null")
    
    -- 若 ota_version 不存在，则回退读取系统发行版信息
    if not version or version == "" then
        version = sys.exec(". /etc/openwrt_release && echo $DISTRIB_DESCRIPTION")
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        platform = platform:gsub("%s+", ""),
        version = (version or "Unknown"):gsub("\n", "")
    })
end

-- 获取云端信息并智能识别“用户手动安装”的插件
-- 该功能用于 Safe-Flash 提示用户哪些插件可能会丢失
function m.get_remote_info()
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local url = uci:get("ota", "settings", "url")
    local token = uci:get("ota", "settings", "github_token") or ""
    
    local remote_ver, file_list, changelog = "N/A", "", ""
    local user_pkgs = {}
    
    -- 扫描并筛选标志为 'user installed' 的插件
    local fd = io.popen("opkg list-installed")
    if fd then
        for line in fd:lines() do
            local pkg = line:match("^(%S+)")
            if pkg then
                -- 只有状态文件里明确标记为用户安装的才进入列表
                local check = sys.exec(string.format("grep 'Status: install user installed' /usr/lib/opkg/info/%s.control 2>/dev/null", pkg))
                if check ~= "" then table.insert(user_pkgs, pkg) end
            end
        end
        fd:close()
    end

    -- 通过 wget 获取 GitHub Release 原始数据
    if url and url ~= "" then
        local auth = (token ~= "") and string.format("--header='Authorization: token %s'", token) or ""
        local tmp = "/tmp/ota_remote.json"
        
        if os.execute(string.format("wget -qO %s %s --header='User-Agent: x' --timeout=8 '%s'", tmp, auth, url)) == 0 then
            -- 使用 jsonfilter 快速解析字段
            remote_ver = sys.exec(string.format("jsonfilter -i %s -e '@.tag_name'", tmp)):gsub("\n", "")
            changelog = sys.exec(string.format("jsonfilter -i %s -e '@.body'", tmp)) or ""
            file_list = sys.exec(string.format("jsonfilter -i %s -e '@.assets[*].name' | grep -E '[.](img[.]gz|img|bin)$'", tmp)) or ""
            os.remove(tmp)
        else
            remote_ver = "Cloud Connection Failed"
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        remote_version = remote_ver,
        files = file_list,
        log = changelog,
        user_packages = user_pkgs
    })
end

-- 核心动作：启动后台升级脚本 (ota.sh)
function m.start_upgrade()
    local http = require "luci.http"
    local selected_file = http.formvalue("filename")
    local keep_config = http.formvalue("keep") or "1"
    local manual_plugins = http.formvalue("manual_plugins") or ""
    
    -- 1. 环境清理：重置所有状态文件和审计报告
    os.execute("rm -rf /tmp/ota_update_ready /tmp/ota_state.json /tmp/ota_build.log /tmp/ota_manual_plugins /tmp/ota_audit_report.txt")
    
    -- 2. 互斥检查：防止并发运行多个升级进程
    if os.execute("pgrep -f /usr/bin/ota.sh > /dev/null") == 0 then
        http.prepare_content("application/json")
        http.write_json({ok = false, msg = "升级任务正在运行中，请勿重复操作"})
        return
    end

    -- 3. 持久化手动补充的插件列表，供 ota.sh 读取
    if manual_plugins ~= "" then
        local f = io.open("/tmp/ota_manual_plugins", "w")
        if f then f:write(manual_plugins); f:close() end
    end

    -- 4. 异步调用核心 Shell 脚本
    -- 使用后台运行符号 '&' 立即返回响应给前端，防止 HTTP 超时
    local cmd = string.format("/usr/bin/ota.sh '%s' '%s'", (selected_file or ""):gsub("'", ""), keep_config)
    os.execute(cmd .. " > /tmp/ota_build.log 2>&1 &")
    
    http.prepare_content("application/json")
    http.write_json({ok = true})
end

return m