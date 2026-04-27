--[[
    LuCI OTA 升级插件 - 控制器 (Controller)
    
    功能特性：
    1. 动态菜单：检测更新后自动在菜单栏显示红点提醒。
    2. 进度追踪：支持固件刷写阶段及重启后插件恢复阶段的双重进度获取。
    3. 安全审计：读取配置冲突报告，供前端展示潜在的覆盖风险。
    4. 备份保护：提供一键预防性系统备份下载接口。
    5. 智能识别：自动分析用户手动安装的插件列表，实现 Safe-Flash 保护。
    6. 预发布识别：支持 GitHub Pre-release 固件识别与筛选。
]]--

local m = {}

function m.index()
    local fs = require "nixio.fs"
    
    -- --- 1. 动态菜单与红点逻辑 ---
    local update_ready = fs.access("/tmp/ota_update_ready")
    local main_title = update_ready and _("OTA 升级 ●") or _("OTA 升级")

    entry({"admin", "system", "ota"}, alias("admin", "system", "ota", "client"), main_title, 60).dependent = true
    entry({"admin", "system", "ota", "client"}, template("ota/index"), _("固件升级"), 10).leaf = true
    entry({"admin", "system", "ota", "config"}, cbi("ota"), _("设置"), 20).leaf = true

    -- --- 2. 接口映射 (AJAX API) ---
    entry({"admin", "system", "ota", "info"}, call("get_info")).leaf = true
    entry({"admin", "system", "ota", "check_update"}, call("get_remote_info")).leaf = true
    entry({"admin", "system", "ota", "start"}, call("start_upgrade")).leaf = true
    entry({"admin", "system", "ota", "state"}, call("get_state")).leaf = true
    entry({"admin", "system", "ota", "log"}, call("get_log")).leaf = true
    entry({"admin", "system", "ota", "audit_report"}, call("action_get_audit")).leaf = true
    entry({"admin", "system", "ota", "backup"}, call("action_backup")).leaf = true
    entry({"admin", "system", "ota", "restore_status"}, call("get_restore_status")).leaf = true
end

-- --- 3. 业务逻辑实现 ---

-- 获取配置审计详情
function m.action_get_audit()
    local fs = require "nixio.fs"
    local report_path = "/tmp/ota_audit_report.txt"
    if fs.access(report_path) then
        local content = fs.readfile(report_path)
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write(content)
    else
        luci.http.status(404, "No Audit Report")
    end
end

-- 获取实时升级状态
function m.get_state()
    local fs = require "nixio.fs"
    local data = fs.readfile("/tmp/ota_state.json")
    luci.http.prepare_content("application/json")
    if data and #data > 5 then 
        luci.http.write(data)
    else
        luci.http.write_json({state = "IDLE", msg = "等待操作", progress = 0})
    end
end

-- 获取重启后的插件恢复进度
function m.get_restore_status()
    local fs = require "nixio.fs"
    local status_path = "/etc/config/ota_restore_status"
    luci.http.prepare_content("application/json")
    if fs.access(status_path) then
        luci.http.write(fs.readfile(status_path))
    else
        luci.http.status(404, "No Active Restore Task")
    end
end

-- 读取实时日志
function m.get_log()
    local fs = require "nixio.fs"
    local log_content = fs.readfile("/tmp/ota_build.log") or "等待日志输出..."
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(log_content)
end

-- 执行预防性系统备份下载
function m.action_backup()
    local fs = require "nixio.fs"
    local util = require "luci.util"
    local backup_path = "/tmp/ota_backup.tar.gz"
    os.execute(string.format("sysupgrade --create-backup %s >/dev/null 2>&1", backup_path))
    if fs.access(backup_path) then
        local board = util.exec("cat /tmp/sysinfo/board_name 2>/dev/null"):trim() or "openwrt"
        luci.http.header("Content-Disposition", 'attachment; filename="backup-%s-%s.tar.gz"' % {
            os.date("%Y%m%d"), board
        })
        luci.http.prepare_content("application/x-targz")
        local f = io.open(backup_path, "r")
        if f then
            while true do
                local block = f:read(4096)
                if not block then break end
                luci.http.write(block)
            end
            f:close()
        end
        fs.unlink(backup_path)
    else
        luci.http.status(500, "Backup failed")
    end
end

-- 获取本地硬件信息
function m.get_info()
    local sys = require "luci.sys"
    local platform = sys.exec("uname -m") or "Unknown"
    local version = sys.exec("cat /etc/ota_version 2>/dev/null")
    if not version or version == "" then
        version = sys.exec(". /etc/openwrt_release && echo $DISTRIB_DESCRIPTION")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        platform = platform:gsub("%s+", ""),
        version = (version or "Unknown"):gsub("\n", "")
    })
end

-- [重点修改] 获取云端信息：整合 Pre-release 识别逻辑
function m.get_remote_info()
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    
    -- 获取设置参数
    local url = uci:get("ota", "settings", "url")
    local token = uci:get("ota", "settings", "github_token") or ""
    local allow_pre = uci:get("ota", "settings", "allow_prerelease") or "0" -- 从配置读取是否允许预发布
    
    local remote_ver, file_list, changelog = "N/A", "", ""
    local user_pkgs = {}
    
    -- 1. 扫描用户手动安装的插件 (Safe-Flash 逻辑保留)
    local fd = io.popen("opkg list-installed")
    if fd then
        for line in fd:lines() do
            local pkg = line:match("^(%S+)")
            if pkg then
                local check = sys.exec(string.format("grep 'Status: install user installed' /usr/lib/opkg/info/%s.control 2>/dev/null", pkg))
                if check ~= "" then table.insert(user_pkgs, pkg) end
            end
        end
        fd:close()
    end

    -- 2. 请求 GitHub API 并处理 Pre-release
    if url and url ~= "" then
        -- 核心步骤：将 /latest 替换为 /releases 以获取包含预发布版的列表
        local api_url = url:gsub("/latest$", "")
        if not api_url:find("/releases$") then api_url = api_url .. "/releases" end

        local auth = (token ~= "") and string.format("--header='Authorization: token %s'", token) or ""
        local tmp = "/tmp/ota_remote.json"
        
        -- 下载 Release 列表
        if os.execute(string.format("wget -qO %s %s --header='User-Agent: x' --timeout=8 '%s'", tmp, auth, api_url)) == 0 then
            
            -- 构建筛选器字符串
            -- 若 allow_pre 为 1，取数组第 0 个（无论是否预发布）
            -- 若 allow_pre 为 0，筛选 prerelease 为 false 的第一个
            local filter_prefix = (allow_pre == "1") and "@[0]" or "@[?(@.prerelease==false)][0]"
            
            remote_ver = sys.exec(string.format("jsonfilter -i %s -e '%s.tag_name'", tmp, filter_prefix)):gsub("\n", "")
            changelog = sys.exec(string.format("jsonfilter -i %s -e '%s.body'", tmp, filter_prefix)) or ""
            file_list = sys.exec(string.format("jsonfilter -i %s -e '%s.assets[*].name' | grep -E '[.](img[.]gz|img|bin)$'", tmp, filter_prefix)) or ""
            
            -- 检查当前选中的版本是否为预发布版
            local is_pre = sys.exec(string.format("jsonfilter -i %s -e '%s.prerelease'", tmp, filter_prefix)):gsub("\n", "")
            if is_pre == "true" then
                remote_ver = remote_ver .. " (Pre-release)"
            end
            
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

-- 启动升级任务
function m.start_upgrade()
    local http = require "luci.http"
    local selected_file = http.formvalue("filename")
    local keep_config = http.formvalue("keep") or "1"
    local manual_plugins = http.formvalue("manual_plugins") or ""
    
    os.execute("rm -rf /tmp/ota_update_ready /tmp/ota_state.json /tmp/ota_build.log /tmp/ota_manual_plugins /tmp/ota_audit_report.txt")
    
    if os.execute("pgrep -f /usr/bin/ota.sh > /dev/null") == 0 then
        http.prepare_content("application/json")
        http.write_json({ok = false, msg = "升级任务正在运行中"})
        return
    end

    if manual_plugins ~= "" then
        local f = io.open("/tmp/ota_manual_plugins", "w")
        if f then f:write(manual_plugins); f:close() end
    end

    local cmd = string.format("/usr/bin/ota.sh '%s' '%s'", (selected_file or ""):gsub("'", ""), keep_config)
    os.execute(cmd .. " > /tmp/ota_build.log 2>&1 &")
    
    http.prepare_content("application/json")
    http.write_json({ok = true})
end

return m