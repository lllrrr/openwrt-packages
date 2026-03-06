local m, s, o
local util = require "luci.util"
local sys = require "luci.sys"

m = Map("socks-clash", "定时任务",
    "配置 SocksClash 的定时任务，包括订阅更新、内核更新、服务重启等。")

-- Cron Jobs Section
s = m:section(TypedSection, "socks-clash", "定时任务设置")
s.anonymous = true
s.addremove = false

-- 订阅自动更新
o = s:option(Flag, "auto_update_sub", "自动更新订阅",
    "定期自动更新所有已启用的订阅")
o.default = "0"
o.rmempty = false

o = s:option(Value, "auto_update_sub_time", "更新时间",
    "Cron 表达式，格式：分 时 日 月 周")
o:value("0 */6 * * *", "每 6 小时")
o:value("0 6 * * *", "每天 6:00")
o:value("0 6 * * 0", "每周日 6:00")
o:value("0 6 1 * *", "每月 1 日 6:00")
o.default = "0 6 * * *"
o.placeholder = "0 6 * * *"
o:depends("auto_update_sub", "1")

-- 内核自动更新
o = s:option(Flag, "auto_update_core", "自动更新内核",
    "定期检查并更新 Clash Meta 内核到最新版本")
o.default = "0"
o.rmempty = false

o = s:option(Value, "auto_update_core_time", "更新时间",
    "Cron 表达式")
o:value("0 4 * * 0", "每周日 4:00")
o:value("0 4 1 * *", "每月 1 日 4:00")
o.default = "0 4 * * 0"
o.placeholder = "0 4 * * 0"
o:depends("auto_update_core", "1")

-- GeoIP/GeoSite 自动更新
o = s:option(Flag, "auto_update_geo", "自动更新 GeoIP/GeoSite",
    "定期更新 GeoIP 和 GeoSite 数据库")
o.default = "0"
o.rmempty = false

o = s:option(Value, "auto_update_geo_time", "更新时间",
    "Cron 表达式")
o:value("0 5 * * *", "每天 5:00")
o:value("0 5 * * 0", "每周日 5:00")
o.default = "0 5 * * 0"
o.placeholder = "0 5 * * 0"
o:depends("auto_update_geo", "1")

-- 定时重启服务
o = s:option(Flag, "auto_restart", "定时重启服务",
    "定期重启 SocksClash 服务以清理连接")
o.default = "0"
o.rmempty = false

o = s:option(Value, "auto_restart_time", "重启时间",
    "Cron 表达式")
o:value("0 3 * * *", "每天 3:00")
o:value("0 3 * * 0", "每周日 3:00")
o.default = "0 3 * * 0"
o.placeholder = "0 3 * * 0"
o:depends("auto_restart", "1")

-- Current Cron Jobs Display
s = m:section(TypedSection, "socks-clash", "当前定时任务")
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_cron_status", "状态")
o.rawhtml = true
o.value = function()
    local cron_content = sys.exec("crontab -l 2>/dev/null | grep socks-clash")
    if cron_content and #cron_content > 0 then
        return "<pre>" .. util.pcdata(cron_content) .. "</pre>"
    else
        return "<em>暂无定时任务</em>"
    end
end

-- Manual Operations
s = m:section(TypedSection, "socks-clash", "手动操作")
s.anonymous = true
s.addremove = false

o = s:option(Button, "apply_cron", "应用定时任务",
    "应用上述定时任务设置到系统 Cron")
o.inputtitle = "立即应用"
o.inputstyle = "apply"
o.write = function()
    -- 清除旧的定时任务
    sys.exec("crontab -l 2>/dev/null | grep -v socks-clash | crontab -")
    
    local auto_update_sub = m:get("config", "auto_update_sub")
    local auto_update_sub_time = m:get("config", "auto_update_sub_time")
    local auto_update_core = m:get("config", "auto_update_core")
    local auto_update_core_time = m:get("config", "auto_update_core_time")
    local auto_update_geo = m:get("config", "auto_update_geo")
    local auto_update_geo_time = m:get("config", "auto_update_geo_time")
    local auto_restart = m:get("config", "auto_restart")
    local auto_restart_time = m:get("config", "auto_restart_time")
    
    local cron_file = "/tmp/socks_clash_cron.tmp"
    local f = io.open(cron_file, "w")
    
    -- 获取现有的 cron 任务
    f:write(sys.exec("crontab -l 2>/dev/null | grep -v socks-clash") or "")
    
    if auto_update_sub == "1" and auto_update_sub_time then
        f:write(auto_update_sub_time .. " /usr/share/socks-clash/update_subscribe.sh >/dev/null 2>&1 # socks-clash-sub\n")
    end
    
    if auto_update_core == "1" and auto_update_core_time then
        f:write(auto_update_core_time .. " /usr/share/socks-clash/download_core.sh update >/dev/null 2>&1 # socks-clash-core\n")
    end
    
    if auto_update_geo == "1" and auto_update_geo_time then
        f:write(auto_update_geo_time .. " /usr/share/socks-clash/update_geo.sh >/dev/null 2>&1 # socks-clash-geo\n")
    end
    
    if auto_restart == "1" and auto_restart_time then
        f:write(auto_restart_time .. " /etc/init.d/socks-clash restart >/dev/null 2>&1 # socks-clash-restart\n")
    end
    
    f:close()
    
    sys.exec("crontab " .. cron_file)
    sys.exec("rm -f " .. cron_file)
    sys.exec("/etc/init.d/cron restart")
    
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "socks-clash", "cron"))
end

o = s:option(Button, "clear_cron", "清除所有定时任务")
o.inputtitle = "清除"
o.inputstyle = "reset"
o.write = function()
    sys.exec("crontab -l 2>/dev/null | grep -v socks-clash | crontab -")
    sys.exec("/etc/init.d/cron restart")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "socks-clash", "cron"))
end

return m
