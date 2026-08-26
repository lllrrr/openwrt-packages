-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"

m = Map("network", translate("Port Manager"),
    translate("Manage WAN/LAN port assignment. Supports DSA architecture."))

-- ============================================================
-- 第一部分：当前状态展示
-- ============================================================
s = m:section(TypedSection, "port_status", translate("Current Port Status"))
s.anonymous = true

-- 获取当前状态
local all_ports = {}
local lan_ports = {}
local wan_port = ""
local pending_rollback = "no"
local port_info = {}

local status_output = luci.sys.exec("/usr/libexec/systools/port_manager.sh status 2>/dev/null")
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "all_ports" then
        for p in value:gmatch("%S+") do
            table.insert(all_ports, p)
        end
    elseif key == "lan_ports" then
        for p in value:gmatch("%S+") do
            table.insert(lan_ports, p)
        end
    elseif key == "wan_port" then
        wan_port = value
    elseif key == "pending_rollback" then
        pending_rollback = value
    elseif key and key:match("^port_(.+)_role$") then
        local port = key:match("^port_(.+)_role$")
        port_info[port] = port_info[port] or {}
        port_info[port].role = value
    elseif key and key:match("^port_(.+)_speed$") then
        local port = key:match("^port_(.+)_speed$")
        port_info[port] = port_info[port] or {}
        port_info[port].speed = value
    elseif key and key:match("^port_(.+)_carrier$") then
        local port = key:match("^port_(.+)_carrier$")
        port_info[port] = port_info[port] or {}
        port_info[port].carrier = value
    end
end

-- 如果没有获取到网口，使用默认列表
if #all_ports == 0 then
    all_ports = {"eth1", "lan2", "lan3", "lan4"}
    wan_port = "eth1"
    lan_ports = {"lan2", "lan3", "lan4"}
    for _, p in ipairs(all_ports) do
        port_info[p] = port_info[p] or {}
        port_info[p].role = (p == "eth1") and "wan" or "lan"
        port_info[p].speed = "unknown"
        port_info[p].carrier = "down"
    end
end

-- 待确认提示
if pending_rollback == "yes" then
    o = s:option(DummyValue, "_pending", translate("Pending Confirmation"))
    o.value = '<div style="background:#fff3cd;border:1px solid #ffc107;border-radius:4px;padding:10px;margin:5px 0;color:#856404;">' ..
        '<strong>' .. translate("Configuration pending confirmation") .. '</strong><br>' ..
        translate("New port configuration has been applied. If not confirmed within 30 seconds, it will automatically rollback.") ..
        '</div>'
    o.rawhtml = true
end

-- 网口状态表格
o = s:option(DummyValue, "_port_table", translate("Port List"))
local table_html = '<table class="table" style="width:100%;border-collapse:collapse;margin:10px 0;">'
table_html = table_html .. '<tr style="background:#f5f5f5;">'
table_html = table_html .. '<th style="padding:8px;border:1px solid #ddd;text-align:left;">' .. translate("Port") .. '</th>'
table_html = table_html .. '<th style="padding:8px;border:1px solid #ddd;text-align:left;">' .. translate("Role") .. '</th>'
table_html = table_html .. '<th style="padding:8px;border:1px solid #ddd;text-align:left;">' .. translate("Speed") .. '</th>'
table_html = table_html .. '<th style="padding:8px;border:1px solid #ddd;text-align:left;">' .. translate("Link") .. '</th>'
table_html = table_html .. '</tr>'

for _, port in ipairs(all_ports) do
    local info = port_info[port] or {}
    local role = info.role or "unused"
    local speed = info.speed or "unknown"
    local carrier = info.carrier or "down"

    local role_text, role_color
    if role == "wan" then
        role_text = translate("WAN")
        role_color = "#1677ff"
    elseif role == "lan" then
        role_text = translate("LAN")
        role_color = "#52c41a"
    else
        role_text = translate("Unused")
        role_color = "#999"
    end

    local speed_text
    if speed == "unknown" or speed == "" then
        speed_text = translate("Unknown")
    elseif tonumber(speed) then
        speed_text = speed .. " Mbps"
    else
        speed_text = speed
    end

    local carrier_text, carrier_color
    if carrier == "up" then
        carrier_text = translate("Connected")
        carrier_color = "#52c41a"
    else
        carrier_text = translate("Disconnected")
        carrier_color = "#999"
    end

    table_html = table_html .. '<tr>'
    table_html = table_html .. '<td style="padding:8px;border:1px solid #ddd;"><strong>' .. port .. '</strong></td>'
    table_html = table_html .. '<td style="padding:8px;border:1px solid #ddd;color:' .. role_color .. ';font-weight:bold;">' .. role_text .. '</td>'
    table_html = table_html .. '<td style="padding:8px;border:1px solid #ddd;">' .. speed_text .. '</td>'
    table_html = table_html .. '<td style="padding:8px;border:1px solid #ddd;color:' .. carrier_color .. ';">' .. carrier_text .. '</td>'
    table_html = table_html .. '</tr>'
end
table_html = table_html .. '</table>'
o.value = table_html
o.rawhtml = true

-- ============================================================
-- 第二部分：网口配置
-- ============================================================
s2 = m:section(TypedSection, "port_config", translate("Port Configuration"))
s2.anonymous = true
s2.description = translate("Select the role for each physical port. At least one LAN port and one WAN port are required.")

-- 为每个网口创建角色选择
for _, port in ipairs(all_ports) do
    local info = port_info[port] or {}
    local current_role = info.role or "unused"

    o = s2:option(ListValue, "role_" .. port, translatef("Port %s", port),
        translate("Select the role for this port"))
    o:value("lan", translate("LAN"))
    o:value("wan", translate("WAN"))
    o:value("unused", translate("Unused"))
    o.default = current_role
    o.rmempty = false

    -- 显示网口速度信息作为提示
    if info.speed and info.speed ~= "unknown" and info.speed ~= "" then
        o.description = translatef("Current speed: %s Mbps", info.speed)
    end
end

-- ============================================================
-- 第三部分：操作按钮
-- ============================================================
s3 = m:section(TypedSection, "port_operations", translate("Operations"))
s3.anonymous = true

-- 应用配置按钮
btn_apply = s3:option(Button, "_apply", translate("Apply Configuration"))
btn_apply.inputtitle = translate("Apply & Restart Network")
btn_apply.inputstyle = "apply"
btn_apply.description = translate("Apply the new port configuration and restart network. A 30-second confirmation countdown will start.")
function btn_apply.write(self, section)
    -- 收集所有网口的角色
    local new_lan = {}
    local new_wan = ""

    for _, port in ipairs(all_ports) do
        local role = m:formvalue("cbid.network.port_config.role_" .. port)
        if role == "lan" then
            table.insert(new_lan, port)
        elseif role == "wan" then
            new_wan = port
        end
    end

    -- 验证：至少1个LAN口
    if #new_lan == 0 then
        m.message = '<div style="color:#dc3545;font-weight:bold;">' .. translate("Error: At least one LAN port is required for management.") .. '</div>'
        return
    end

    -- 验证：至少1个WAN口
    if new_wan == "" then
        m.message = '<div style="color:#dc3545;font-weight:bold;">' .. translate("Error: At least one WAN port is required for internet access.") .. '</div>'
        return
    end

    -- 验证：WAN口不能与LAN口重复
    for _, lp in ipairs(new_lan) do
        if lp == new_wan then
            m.message = '<div style="color:#dc3545;font-weight:bold;">' .. translate("Error: WAN port cannot be the same as LAN port.") .. '</div>'
            return
        end
    end

    -- 构建LAN端口字符串
    local lan_str = table.concat(new_lan, " ")

    -- 调用后台脚本应用配置
    local cmd = string.format("/usr/libexec/systools/port_manager.sh apply %s %s",
        systools_common.shell_escape(lan_str),
        systools_common.shell_escape(new_wan))
    luci.sys.call(cmd .. " >/dev/null 2>&1 &")

    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "port_manager"))
end

-- 确认配置按钮（仅在待确认状态显示）
if pending_rollback == "yes" then
    btn_confirm = s3:option(Button, "_confirm", translate("Confirm Configuration"))
    btn_confirm.inputtitle = translate("Confirm")
    btn_confirm.inputstyle = "save"
    btn_confirm.description = translate("Confirm the new configuration and cancel the rollback countdown.")
    function btn_confirm.write(self, section)
        luci.sys.call("/usr/libexec/systools/port_manager.sh confirm >/dev/null 2>&1 &")
        luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "port_manager"))
    end
end

-- 立即回滚按钮（仅在待确认状态显示）
if pending_rollback == "yes" then
    btn_rollback = s3:option(Button, "_rollback", translate("Rollback Now"))
    btn_rollback.inputtitle = translate("Rollback")
    btn_rollback.inputstyle = "reset"
    btn_rollback.description = translate("Immediately rollback to the previous configuration.")
    function btn_rollback.write(self, section)
        luci.sys.call("/usr/libexec/systools/port_manager.sh rollback >/dev/null 2>&1 &")
        luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "port_manager"))
    end
end

-- 恢复备份按钮
btn_restore = s3:option(Button, "_restore", translate("Restore Previous Configuration"))
btn_restore.inputtitle = translate("Restore")
btn_restore.inputstyle = "reset"
btn_restore.description = translate("Restore from the most recent backup.")
function btn_restore.write(self, section)
    luci.sys.call("/usr/libexec/systools/port_manager.sh restore >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "port_manager"))
end

-- 恢复默认配置按钮
btn_default = s3:option(Button, "_default", translate("Restore Default Configuration"))
btn_default.inputtitle = translate("Restore Default")
btn_default.inputstyle = "reset"
btn_default.description = translate("Restore to factory default port assignment (LAN: lan2/lan3/lan4, WAN: eth1).")
function btn_default.write(self, section)
    luci.sys.call("/usr/libexec/systools/port_manager.sh default >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "port_manager"))
end

-- ============================================================
-- 第四部分：使用说明
-- ============================================================
s4 = m:section(TypedSection, "port_help", translate("Help & Notes"))
s4.anonymous = true

o = s4:option(DummyValue, "_help", translate("Important Notes"))
o.value = '<div style="background:#e7f3ff;border:1px solid #91caff;border-radius:4px;padding:12px;margin:5px 0;line-height:1.8;">' ..
    '<strong>' .. translate("Important Notes") .. '</strong><br>' ..
    '1. ' .. translate("At least one LAN port must be reserved for router management access.") .. '<br>' ..
    '2. ' .. translate("At least one WAN port must be reserved for internet connection.") .. '<br>' ..
    '3. ' .. translate("After applying, you have 30 seconds to confirm. If not confirmed, it will automatically rollback.") .. '<br>' ..
    '4. ' .. translate("Changing port assignment will restart the network service and temporarily disconnect all connections.") .. '<br>' ..
    '5. ' .. translate("The 2.5G port (eth1) is recommended as WAN for maximum internet speed.") .. '<br>' ..
    '6. ' .. translate("This plugin supports DSA architecture. For swconfig devices, please use the switch VLAN configuration page instead.") ..
    '</div>'
o.rawhtml = true

return m
