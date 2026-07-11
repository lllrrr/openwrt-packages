-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"

m = Map("systools", translate("Network Settings"),
    translate("Manage smart home network settings: ports, mDNS, UPnP."))

-- 常用端口管理
s = m:section(TypedSection, "smarthome", translate("Common Ports"))
s.anonymous = true
s.description = translate("Quickly open/close common smart home service ports.")

-- 获取端口列表
local ports_output = luci.sys.exec("/usr/libexec/systools/smarthome_network.sh ports_list 2>/dev/null")
local ports = {}
for line in ports_output:gmatch("[^\r\n]+") do
    local port, name, proto, status = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if port then
        table.insert(ports, {
            port = port,
            name = name,
            proto = proto,
            status = status
        })
    end
end

if #ports == 0 then
    o = s:option(DummyValue, "_empty", "")
    o.value = '<div style="color:gray;text-align:center;padding:20px;">' ..
        translate("No ports configured") ..
        '</div>'
    o.rawhtml = true
else
    -- 显示端口表格（标准CBI风格，单form多按钮）
    local html = '<form method="post" class="cbi-section-table-form">'
    html = html .. '<input type="hidden" name="cbi.submit" value="1">'
    html = html .. '<table class="cbi-table table cbi-section-table" style="width:100%">'
    html = html .. '<tr class="cbi-section-table-titles">'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("Service") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("Port") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("Protocol") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("Status") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell cbi-section-actions">' .. translate("Actions") .. '</th>'
    html = html .. '</tr>'
    
    for _, p in ipairs(ports) do
        local status_color = p.status == "open" and "green" or "gray"
        local status_text = p.status == "open" and translate("Open") or translate("Closed")
        local btn_action = p.status == "open" and "close" or "open"
        local btn_style = p.status == "open" and "cbi-button-negative cbi-button-reset" or "cbi-button-positive cbi-button-apply"
        local btn_text = p.status == "open" and translate("Close") or translate("Open")
        
        html = html .. '<tr class="cbi-section-table-row">'
        html = html .. '<td class="cbi-section-table-cell"><strong>' .. p.name .. '</strong></td>'
        html = html .. '<td class="cbi-section-table-cell">' .. p.port .. '</td>'
        html = html .. '<td class="cbi-section-table-cell">' .. p.proto:upper() .. '</td>'
        html = html .. '<td class="cbi-section-table-cell"><span style="color:' .. status_color .. '"><strong>' .. status_text .. '</strong></span></td>'
        html = html .. '<td class="cbi-section-table-cell cbi-section-actions">'
        html = html .. '<button type="submit" name="cbid.systools.smarthome._port_' .. btn_action .. '_' .. p.port .. '_' .. p.proto .. '" '
        html = html .. 'class="cbi-button ' .. btn_style .. '">'
        html = html .. btn_text .. '</button>'
        html = html .. '</td>'
        html = html .. '</tr>'
    end
    
    html = html .. '</table>'
    html = html .. '</form>'
    
    o = s:option(DummyValue, "_table", "")
    o.value = html
    o.rawhtml = true
end
for _, p in ipairs(ports) do
    if formvalue("cbid.systools.smarthome._port_open_" .. p.port .. "_" .. p.proto) then
        luci.sys.call(string.format("/usr/libexec/systools/smarthome_network.sh port_open %s %s %s >/dev/null 2>&1 &",
            systools_common.shell_escape(p.port), systools_common.shell_escape(p.proto), systools_common.shell_escape(p.name)))
        luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
    end
    if formvalue("cbid.systools.smarthome._port_close_" .. p.port .. "_" .. p.proto) then
        luci.sys.call(string.format("/usr/libexec/systools/smarthome_network.sh port_close %s %s >/dev/null 2>&1 &",
            systools_common.shell_escape(p.port), systools_common.shell_escape(p.proto)))
        luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
    end
end

-- mDNS 设置
s2 = m:section(TypedSection, "smarthome", translate("mDNS Service"))
s2.anonymous = true
s2.description = translate("mDNS (Multicast DNS) for smart home device discovery.")

local mdns_output = luci.sys.exec("/usr/libexec/systools/smarthome_network.sh mdns_status 2>/dev/null")
local mdns_status = "stopped"
local mdns_service = "none"
for line in mdns_output:gmatch("[^\r\n]+") do
    if line:match("^running") then
        mdns_status = "running"
    elseif line:match("^service=") then
        mdns_service = line:match("^service=(.*)$")
    end
end

o = s2:option(DummyValue, "_mdns_status", translate("Status"))
if mdns_status == "running" then
    o.value = '<span style="color:green"><strong>' .. translate("Running") .. '</strong></span> (' .. mdns_service .. ')'
else
    o.value = '<span style="color:gray"><strong>' .. translate("Stopped") .. '</strong></span>'
end
o.rawhtml = true

btn_mdns_enable = s2:option(Button, "_mdns_enable", translate("Enable mDNS"))
btn_mdns_enable.inputtitle = translate("Enable")
btn_mdns_enable.inputstyle = "apply"
btn_mdns_enable.description = translate("Start mDNS service for device discovery")
function btn_mdns_enable.write(self, section)
    luci.sys.call("/usr/libexec/systools/smarthome_network.sh mdns_enable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
end

btn_mdns_disable = s2:option(Button, "_mdns_disable", translate("Disable mDNS"))
btn_mdns_disable.inputtitle = translate("Disable")
btn_mdns_disable.inputstyle = "reset"
btn_mdns_disable.description = translate("Stop mDNS service")
function btn_mdns_disable.write(self, section)
    luci.sys.call("/usr/libexec/systools/smarthome_network.sh mdns_disable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
end

-- UPnP 设置
s3 = m:section(TypedSection, "smarthome", translate("UPnP Service"))
s3.anonymous = true
s3.description = translate("UPnP (Universal Plug and Play) for automatic port forwarding.")

local upnp_output = luci.sys.exec("/usr/libexec/systools/smarthome_network.sh upnp_status 2>/dev/null")
local upnp_status = "stopped"
local upnp_service = "none"
for line in upnp_output:gmatch("[^\r\n]+") do
    if line:match("^running") then
        upnp_status = "running"
    elseif line:match("^service=") then
        upnp_service = line:match("^service=(.*)$")
    end
end

o = s3:option(DummyValue, "_upnp_status", translate("Status"))
if upnp_status == "running" then
    o.value = '<span style="color:green"><strong>' .. translate("Running") .. '</strong></span> (' .. upnp_service .. ')'
else
    o.value = '<span style="color:gray"><strong>' .. translate("Stopped") .. '</strong></span>'
end
o.rawhtml = true

btn_upnp_enable = s3:option(Button, "_upnp_enable", translate("Enable UPnP"))
btn_upnp_enable.inputtitle = translate("Enable")
btn_upnp_enable.inputstyle = "apply"
btn_upnp_enable.description = translate("Start UPnP service for automatic port forwarding")
function btn_upnp_enable.write(self, section)
    luci.sys.call("/usr/libexec/systools/smarthome_network.sh upnp_enable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
end

btn_upnp_disable = s3:option(Button, "_upnp_disable", translate("Disable UPnP"))
btn_upnp_disable.inputtitle = translate("Disable")
btn_upnp_disable.inputstyle = "reset"
btn_upnp_disable.description = translate("Stop UPnP service")
function btn_upnp_disable.write(self, section)
    luci.sys.call("/usr/libexec/systools/smarthome_network.sh upnp_disable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "network"))
end

return m
