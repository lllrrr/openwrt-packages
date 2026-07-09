-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

m = Map("systools", translate("Side Route Mode"),
    translate("One-click switch between normal router mode and side route mode. Side route mode allows the router to work as a bypass gateway for proxy and special network processing."))

s = m:section(TypedSection, "side_route", translate("Current Status"))
s.anonymous = true

-- 获取当前状态
local mode = "normal"
local lan_ip = "N/A"
local gateway = "N/A"
local dhcp_enabled = "unknown"

local status_output = luci.sys.exec("/usr/libexec/systools/side_route.sh status 2>/dev/null")
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "mode" then mode = value end
    if key == "lan_ip" then lan_ip = value end
    if key == "gateway" then gateway = value end
    if key == "dhcp_enabled" then dhcp_enabled = value end
end

-- 当前模式
o = s:option(DummyValue, "_mode", translate("Current Mode"))
if mode == "side_route" then
    o.value = '<span style="color:orange;font-weight:bold">' .. translate("Side Route Mode") .. '</span>'
else
    o.value = '<span style="color:green;font-weight:bold">' .. translate("Normal Router Mode") .. '</span>'
end
o.rawhtml = true

-- LAN IP
o = s:option(DummyValue, "_lan_ip", translate("LAN IP Address"))
o.value = lan_ip

-- 默认网关
o = s:option(DummyValue, "_gateway", translate("Default Gateway"))
o.value = gateway

-- DHCP 状态
o = s:option(DummyValue, "_dhcp", translate("DHCP Server"))
if dhcp_enabled == "yes" then
    o.value = '<span style="color:green">' .. translate("Enabled") .. '</span>'
else
    o.value = '<span style="color:red">' .. translate("Disabled") .. '</span>'
end
o.rawhtml = true

-- 操作按钮
s2 = m:section(TypedSection, "side_route", translate("Operations"))
s2.anonymous = true

-- 切换到旁路由模式
btn_enable = s2:option(Button, "_enable", translate("Switch to Side Route Mode"))
btn_enable.inputtitle = translate("Enable Side Route")
btn_enable.inputstyle = "apply"
btn_enable.description = translate("Automatically detect network environment and switch to side route mode. The router will work as a bypass gateway.")
function btn_enable.write(self, section)
    luci.sys.call("/usr/libexec/systools/side_route.sh enable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "side_route"))
end

-- 恢复正常模式
btn_disable = s2:option(Button, "_disable", translate("Restore Normal Mode"))
btn_disable.inputtitle = translate("Restore Normal Mode")
btn_disable.inputstyle = "reset"
btn_disable.description = translate("Restore to normal router mode from backup.")
function btn_disable.write(self, section)
    luci.sys.call("/usr/libexec/systools/side_route.sh disable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "side_route"))
end

-- 重要提示
s3 = m:section(TypedSection, "side_route", translate("Important Notes"))
s3.anonymous = true

o = s3:option(DummyValue, "_warning")
o.value = '<div style="background-color: #fff3cd; border: 1px solid #ffeeba; padding: 15px; border-radius: 4px; color: #856404;"><strong>' .. translate("Warning") .. '：</strong><ul style="margin: 10px 0; padding-left: 20px;"><li>' .. translate("Switching modes will cause network interruption for a few seconds") .. '</li><li>' .. translate("In side route mode, the DHCP server will be turned off") .. '</li><li>' .. translate("Devices need to manually set the gateway to the router's IP to use side route") .. '</li><li>' .. translate("Or set the gateway in the main router's DHCP settings") .. '</li><li>' .. translate("Configuration is automatically backed up before switching, and can be restored if there are issues") .. '</li></ul></div>'
o.rawhtml = true

return m
