-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"

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


-- 检查容器是否存在，不存在则显示创建向导
if ha_status.status == "not_found" then
    -- 创建向导
    s_wizard = m:section(TypedSection, "smarthome", translate("创建 Home Assistant 容器"))
    s_wizard.anonymous = true
    s_wizard.description = translate("检测到 Home Assistant 容器不存在，使用向导快速创建")

    -- 镜像源选择
    o = s_wizard:option(ListValue, "image_source", translate("镜像源"))
    o:value("official", translate("官方源 (ghcr.io)"))
    o.datatype = "string"
    o:value("aliyun", translate("阿里云镜像"))
    o:value("netease", translate("网易云镜像"))
    o:value("ustc", translate("中科大镜像"))
    o:value("custom", translate("自定义镜像"))
    o.default = "aliyun"
    o.rmempty = false

    -- 自定义镜像地址
    o = s_wizard:option(Value, "custom_image", translate("自定义镜像地址"))
    o.description = translate("选择自定义镜像源时填写，例如：registry.example.com/ha:latest")
    o.datatype = "string"
    o.placeholder = "ghcr.io/home-assistant/home-assistant:stable"
    o:depends("image_source", "custom")

    -- 容器名称
    o = s_wizard:option(Value, "container_name", translate("容器名称"))
    o.default = "homeassistant"
    o.datatype = "hostname"
    o.rmempty = false

    -- 端口映射（bridge模式下）
    o = s_wizard:option(Value, "host_port", translate("主机端口映射"))
    o.default = "8123"
    o.datatype = "port"
    o.description = translate("Bridge 网络模式下映射到主机的端口")

    -- 数据卷路径
    o = s_wizard:option(Value, "config_path", translate("配置目录路径"))
    o.default = "/etc/homeassistant"
    o.datatype = "string"
    o.description = translate("Home Assistant 配置文件存储路径，建议使用 U 盘等持久化存储")

    -- 网络模式
    o = s_wizard:option(ListValue, "network_mode", translate("网络模式"))
    o:value("host", translate("Host 模式（推荐，设备发现更全）"))
    o:value("bridge", translate("Bridge 模式"))
    o.default = "host"
    o.rmempty = false

    -- 创建按钮
    btn_create = s_wizard:option(Button, "_create_btn", translate("创建并启动容器"))
    btn_create.inputtitle = translate("创建容器")
    btn_create.inputstyle = "apply"
    btn_create.write = function(self, section)
        local image_source = http.formvalue("cbid.systools.smarthome.image_source")
        local custom_image = http.formvalue("cbid.systools.smarthome.custom_image")
        local container_name = http.formvalue("cbid.systools.smarthome.container_name")
        local host_port = http.formvalue("cbid.systools.smarthome.host_port")
        local config_path = http.formvalue("cbid.systools.smarthome.config_path")
        local network_mode = http.formvalue("cbid.systools.smarthome.network_mode")

        -- 确定镜像地址
        local image
        if image_source == "official" then
            image = "ghcr.io/home-assistant/home-assistant:stable"
        elseif image_source == "aliyun" then
            image = "registry.cn-hangzhou.aliyuncs.com/home-assistant/home-assistant:stable"
        elseif image_source == "netease" then
            image = "hub-mirror.c.163.com/homeassistant/home-assistant:stable"
        elseif image_source == "ustc" then
            image = "docker.mirrors.ustc.edu.cn/homeassistant/home-assistant:stable"
        else
            image = custom_image or "ghcr.io/home-assistant/home-assistant:stable"
        end

        -- 构建 docker run 命令
        local cmd = "docker run -d "
        cmd = cmd .. "--name " .. systools_common.shell_escape(container_name) .. " "
        cmd = cmd .. "--privileged "
        cmd = cmd .. "--restart=unless-stopped "
        cmd = cmd .. "-e TZ=Asia/Shanghai "
        cmd = cmd .. "-v " .. systools_common.shell_escape(config_path) .. ":/config "
        
        if network_mode == "host" then
            cmd = cmd .. "--network=host "
        else
            cmd = cmd .. "-p " .. systools_common.shell_escape(host_port) .. ":8123 "
        end
        
        cmd = cmd .. systools_common.shell_escape(image)
        cmd = cmd .. " >/tmp/systools_ha_create.log 2>&1 &"

        -- 后台执行创建
        luci.sys.call(cmd)
        
        http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "homeassistant"))
    end

    -- 创建日志
    s_log = m:section(TypedSection, "smarthome", translate("创建进度"))
    s_log.anonymous = true
    
    local create_log = luci.sys.exec("cat /tmp/systools_ha_create.log 2>/dev/null | tail -20")
    if create_log and #create_log > 0 then
        o = s_log:option(DummyValue, "_create_log")
        o.rawhtml = true
        o.value = '<pre style="background:#f5f5f5;padding:10px;border-radius:4px;max-height:200px;overflow:auto;font-size:12px;">' ..
            luci.util.pcdata(create_log) .. '</pre>'
    end

    -- 容器不存在时只显示向导，不显示后面的管理功能
    return m
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
    o.datatype = "string"

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
        local port_info = luci.sys.exec("docker port " .. systools_common.shell_escape(container_id) .. " 2>/dev/null | head -1")
        -- 解析 docker port 输出，格式如：8123/tcp -> 0.0.0.0:8123
        local host_port = port_info:match(":(%d+)%s*$")
        if not host_port or #host_port == 0 then
            host_port = "8123"  -- 兜底默认值
        end
        local host = luci.http.getenv("HTTP_HOST"):gsub(":[0-9]+", "")
        luci.http.redirect("http://" .. host .. ":" .. host_port)
    end
end
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
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "homeassistant"))
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
