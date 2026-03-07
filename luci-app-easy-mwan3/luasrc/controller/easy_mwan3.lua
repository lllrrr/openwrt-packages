-- Easy MWAN3 Controller
-- Copyright (C) 2024 PengCong226
-- Licensed under MIT

local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"
local json = require "luci.jsonc"

module("luci.controller.easy_mwan3", package.seeall)

function index()
    -- 检查 mwan3 是否安装
    if not fs.access("/etc/config/mwan3") then
        return
    end
    
    -- 检查防火墙版本 (fw3/fw4)
    local fw_version = sys.exec("uci get firewall.@defaults[0].name 2>/dev/null || echo 'unknown'")
    if fw_version:match("fw4") then
        -- fw4 不兼容，显示警告
        entry({"admin", "network", "easy_mwan3"}, 
              template("easy_mwan3/incompatible"), 
              _("Easy MWAN3"), 60)
        return
    end
    
    -- 主配置页面
    local page = entry({"admin", "network", "easy_mwan3"}, 
                       cbi("easy_mwan3"), 
                       _("Easy MWAN3"), 60)
    page.dependent = true
    page.acl_dep = {"luci-app-easy-mwan3"}
    
    -- 状态页面
    entry({"admin", "network", "easy_mwan3", "status_view"},
          template("easy_mwan3/status"),
          _("Status"), 61).leaf = true
    
    -- 状态 API
    entry({"admin", "network", "easy_mwan3", "status"},
          call("action_status"),
          nil).leaf = true
    
    -- 应用配置 API
    entry({"admin", "network", "easy_mwan3", "apply"},
          call("action_apply"),
          nil).leaf = true
end

function action_status()
    local status = {}
    
    -- 检查服务状态
    status.mwan3_running = (sys.call("/etc/init.d/mwan3 running >/dev/null 2>&1") == 0)
    status.easy_mwan3_enabled = (sys.call("uci -q get easy_mwan3.global.enabled") == 0)
    
    -- 使用新的状态检测脚本
    local status_script = "/usr/bin/easy_mwan3_status.sh"
    if fs.access(status_script) then
        local result = sys.exec(status_script .. " json 2>/dev/null")
        if result and #result > 0 then
            local decoded = json.parse(result)
            if decoded then
                status.interfaces = decoded
            end
        end
    else
        -- 回退到旧方法
        status.interfaces = get_interfaces_fallback()
    end
    
    http.prepare_content("application/json")
    http.write_json(status)
end

function action_apply()
    local result = {}
    
    -- 检查权限
    if not luci.dispatcher.context.authen then
        http.status(403, "Forbidden")
        result.success = false
        result.message = "Authentication required"
        http.write_json(result)
        return
    end
    
    -- 执行配置应用
    local apply_script = "/usr/bin/easy_mwan3_apply.sh"
    if not fs.access(apply_script) then
        http.status(500, "Internal Server Error")
        result.success = false
        result.message = "Apply script not found"
        http.write_json(result)
        return
    end
    
    local exit_code = sys.call(apply_script .. " >/dev/null 2>&1")
    
    if exit_code == 0 then
        result.success = true
        result.message = "Configuration applied successfully"
    else
        http.status(500, "Internal Server Error")
        result.success = false
        result.message = "Failed to apply configuration. Check logs for details."
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- 回退方法：如果状态脚本不存在
function get_interfaces_fallback()
    local interfaces = {}
    local uci = require "luci.model.uci".cursor()
    
    uci:foreach("mwan3", "interface", function(s)
        local iface = s[".name"]
        local enabled = s.enabled or "1"
        
        table.insert(interfaces, {
            iface = iface,
            status = "unknown",
            uptime = "-",
            load = "-"
        })
    end)
    
    return interfaces
end
