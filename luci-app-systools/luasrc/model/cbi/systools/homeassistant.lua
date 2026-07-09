-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

-- Shell 转义函数，防止命令注入
local function shell_escape(str)
    if not str then return "" end
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

m = Map("systools", translate("Home Assistant"),
    translate("Manage Home Assistant container and configuration."))

-- 加载 Argon 主题适配样式
local css_link = '<link rel="stylesheet" href="/luci-static/resources/systools/systools.css">'

-- 检查 Docker 是否安装
local docker_installed = luci.sys.exec("command -v docker >/dev/null 2>&1 && echo yes || echo no")

-- 加载 Argon 主题适配样式
s_css = m:section(TypedSection, "_css", "")
s_css.anonymous = true
s_css.addremove = false
o_css = s_css:option(DummyValue, "_css_link", "")
o_css.value = css_link
o_css.rawhtml = true

if docker_installed:match("no") then
    s = m:section(TypedSection, "smarthome", translate("Docker Not Installed"))
    s.anonymous = true
    o = s:option(DummyValue, "_warning", "")
    o.value = '<div class="systools-alert systools-alert-warning">' ..
        translate("Docker is not installed. Please install Docker first to use Home Assistant features.") ..
        '</div>'
    o.rawhtml = true
    return m
end

-- Home Assistant 状态
s = m:section(TypedSection, "smarthome", translate("Home Assistant Status"))
s.anonymous = true

-- 获取状态
local status_output = luci.sys.exec("/usr/libexec/systools/homeassistant.sh status 2>/dev/null")
local ha_status = {}
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and value then
        ha_status[key] = value
    end
end

-- 运行状态
o = s:option(DummyValue, "_status", translate("Status"))
if ha_status.running == "yes" then
    o.value = '<span class="systools-text-success" style="font-weight:bold"><span class="systools-status-dot systools-status-dot-success"></span>' .. translate("Running") .. '</span>'
elseif ha_status.status == "not_found" then
    o.value = '<span class="systools-text-muted" style="font-weight:bold"><span class="systools-status-dot systools-status-dot-muted"></span>' .. translate("Not Found") .. '</span>'
else
    o.value = '<span class="systools-text-danger" style="font-weight:bold"><span class="systools-status-dot systools-status-dot-danger"></span>' .. translate("Stopped") .. '</span>'
end
o.rawhtml = true

-- 容器 ID
o = s:option(DummyValue, "_container_id", translate("Container ID"))
o.value = ha_status.container_id or "N/A"

-- 镜像名
o = s:option(DummyValue, "_image", translate("Image"))
o.value = ha_status.image or "N/A"

-- 版本
o = s:option(DummyValue, "_version", translate("Version"))
o.value = ha_status.version or "N/A"

-- CPU 使用率
o = s:option(DummyValue, "_cpu", translate("CPU Usage"))
o.value = ha_status.cpu_usage or "N/A"

-- 内存使用
o = s:option(DummyValue, "_mem", translate("Memory Usage"))
o.value = ha_status.mem_usage or "N/A"

-- 创建时间
o = s:option(DummyValue, "_created", translate("Created"))
o.value = ha_status.created or "N/A"

-- 操作按钮
s2 = m:section(TypedSection, "smarthome", translate("Operations"))
s2.anonymous = true

-- 启动按钮
btn_start = s2:option(Button, "_start", translate("Start HA"))
btn_start.inputtitle = translate("Start")
btn_start.inputstyle = "apply"
btn_start.description = translate("Start Home Assistant container")
function btn_start.write(self, section)
    luci.sys.call("/usr/libexec/systools/homeassistant.sh start >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "homeassistant"))
end

-- 停止按钮
btn_stop = s2:option(Button, "_stop", translate("Stop HA"))
btn_stop.inputtitle = translate("Stop")
btn_stop.inputstyle = "reset"
btn_stop.description = translate("Stop Home Assistant container")
function btn_stop.write(self, section)
    luci.sys.call("/usr/libexec/systools/homeassistant.sh stop >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "homeassistant"))
end

-- 重启按钮
btn_restart = s2:option(Button, "_restart", translate("Restart HA"))
btn_restart.inputtitle = translate("Restart")
btn_restart.inputstyle = "reload"
btn_restart.description = translate("Restart Home Assistant container")
function btn_restart.write(self, section)
    luci.sys.call("/usr/libexec/systools/homeassistant.sh restart >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "homeassistant"))
end

-- 打开 Web 界面
btn_web = s2:option(Button, "_web", translate("Open Web UI"))
btn_web.inputtitle = translate("Open HA Web UI")
btn_web.inputstyle = "apply"
btn_web.description = translate("Open Home Assistant web interface in new tab")
function btn_web.write(self, section)
    -- 获取 HA 的端口和地址
    local container_id = ha_status.container_id
    if container_id and #container_id > 0 then
        local port_info = luci.sys.exec("docker port " .. shell_escape(container_id) .. " 2>/dev/null | head -1")
        luci.http.redirect("http://" .. luci.http.getenv("HTTP_HOST"):gsub(":[0-9]+", "") .. ":8123")
    end
end

-- 日志查看
s3 = m:section(TypedSection, "smarthome", translate("Recent Logs"))
s3.anonymous = true

o = s3:option(TextValue, "_logs", translate("Logs (last 100 lines)"))
o.rows = 20
o.readonly = true
o.cfgvalue = function(self, section)
    local logs = luci.sys.exec("/usr/libexec/systools/homeassistant.sh logs 100 2>/dev/null")
    return logs or translate("No logs available")
end

-- 备份配置
s4 = m:section(TypedSection, "smarthome", translate("Configuration Backup"))
s4.anonymous = true

btn_backup = s4:option(Button, "_backup", translate("Backup Config"))
btn_backup.inputtitle = translate("Backup Now")
btn_backup.inputstyle = "apply"
btn_backup.description = translate("Backup Home Assistant configuration files")
function btn_backup.write(self, section)
    luci.sys.call("/usr/libexec/systools/homeassistant.sh backup >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "backup"))
end

-- 存储统计
s5 = m:section(TypedSection, "smarthome", translate("Storage Usage"))
s5.anonymous = true

local storage_output = luci.sys.exec("/usr/libexec/systools/homeassistant.sh storage 2>/dev/null")
local storage = {}
for line in storage_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and value then
        storage[key] = value
    end
end

o = s5:option(DummyValue, "_config_size", translate("Config Directory"))
o.value = storage.config_size or "N/A"

o = s5:option(DummyValue, "_db_size", translate("Database Size"))
o.value = storage.db_size or "N/A"

o = s5:option(DummyValue, "_backup_size", translate("Backups Size"))
o.value = storage.backup_size or "N/A"

o = s5:option(DummyValue, "_free_space", translate("Free Space"))
o.value = storage.free_space or "N/A"

return m
