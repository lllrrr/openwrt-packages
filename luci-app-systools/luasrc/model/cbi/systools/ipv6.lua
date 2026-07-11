-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"

m = Map("systools", translate("IPv6 Quick Setup"),
    translate("Configure IPv6 network with one click. Supports multiple modes."))

s = m:section(TypedSection, "ipv6", translate("Current Status"))
s.anonymous = true

-- 获取当前状态
local mode = "disabled"
local connected = "no"
local wan_ip = "N/A"
local lan_prefix = "N/A"

local status_output = luci.sys.exec("/usr/libexec/systools/ipv6.sh status 2>/dev/null")
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "mode" then mode = value end
    if key == "connected" then connected = value end
    if key == "wan_ip" then wan_ip = value end
    if key == "lan_prefix" then lan_prefix = value end
end

-- IPv6 状态
o = s:option(DummyValue, "_status", translate("IPv6 Status"))
if connected == "yes" then
    o.value = '<span style="color:green;font-weight:bold">' .. translate("Enabled & Connected") .. '</span>'
elseif mode ~= "disabled" then
    o.value = '<span style="color:orange;font-weight:bold">' .. translate("Enabled but Not Connected") .. '</span>'
else
    o.value = '<span style="color:red;font-weight:bold">' .. translate("Disabled") .. '</span>'
end
o.rawhtml = true

-- 当前模式
o = s:option(DummyValue, "_mode", translate("Current Mode"))
local mode_names = {
    native = translate("Native IPv6"),
    ["6to4"] = translate("6to4 Tunnel"),
    ["6in4"] = translate("6in4 Tunnel"),
    relay = translate("Relay Mode"),
    disabled = translate("Disabled")
}
o.value = mode_names[mode] or mode:upper()

-- WAN IPv6 地址
o = s:option(DummyValue, "_wan_ip", translate("WAN IPv6 Address"))
o.value = wan_ip

-- LAN IPv6 前缀
o = s:option(DummyValue, "_lan_prefix", translate("LAN IPv6 Prefix"))
o.value = lan_prefix

-- 配置区域
s2 = m:section(TypedSection, "ipv6", translate("IPv6 Configuration"))
s2.anonymous = true

-- 模式选择
o = s2:option(ListValue, "ipv6_mode", translate("IPv6 Mode"),
    translate("Select the IPv6 connection mode"))
o:value("native", translate("Native IPv6"))
o:value("6to4", translate("6to4 Tunnel"))
o:value("6in4", translate("6in4 Tunnel"))
o:value("relay", translate("Relay Mode"))
o:value("disabled", translate("Disabled"))
o.default = "native"
o.rmempty = false

-- 6in4 额外配置
s3 = m:section(TypedSection, "ipv6", translate("6in4 Tunnel Configuration"))
s3.anonymous = true
s3:depends("ipv6_mode", "6in4")

o = s3:option(Value, "peeraddr", translate("Tunnel Server Address"),
    translate("6in4 tunnel server IPv4 address"))
o.datatype = "ip4addr"

o = s3:option(Value, "ip6addr", translate("Local IPv6 Address"),
    translate("Your IPv6 address for the tunnel"))
o.datatype = "ip6addr"

o = s3:option(Value, "ip6prefix", translate("IPv6 Prefix"),
    translate("IPv6 prefix for your LAN (optional)"))
o.optional = true

o = s3:option(Value, "tunnelid", translate("Tunnel ID"),
    translate("Tunnel ID / User ID (optional)"))
o.optional = true

o = s3:option(Value, "username", translate("Username"),
    translate("Tunnel service username (optional)"))
o.optional = true

o = s3:option(Value, "password", translate("Password"),
    translate("Tunnel service password (optional)"))
o.password = true
o.optional = true

-- 操作按钮
s4 = m:section(TypedSection, "ipv6", translate("Operations"))
s4.anonymous = true

-- 应用配置按钮
btn_apply = s4:option(Button, "_apply", translate("Apply Configuration"))
btn_apply.inputtitle = translate("Apply & Restart Network")
btn_apply.inputstyle = "apply"
function btn_apply.write(self, section)
    local mode = m:formvalue("cbid.systools.ipv6.ipv6_mode")

    if mode == "native" then
        luci.sys.call("/usr/libexec/systools/ipv6.sh native >/dev/null 2>&1 &")
    elseif mode == "6to4" then
        luci.sys.call("/usr/libexec/systools/ipv6.sh 6to4 >/dev/null 2>&1 &")
    elseif mode == "6in4" then
        local peer = m:formvalue("cbid.systools.ipv6.peeraddr")
        local ip6 = m:formvalue("cbid.systools.ipv6.ip6addr")
        local prefix = m:formvalue("cbid.systools.ipv6.ip6prefix")
        local tid = m:formvalue("cbid.systools.ipv6.tunnelid")
        local user = m:formvalue("cbid.systools.ipv6.username")
        local pass = m:formvalue("cbid.systools.ipv6.password")

        if peer and #peer > 0 then
            local cmd = string.format("/usr/libexec/systools/ipv6.sh 6in4 %s", systools_common.shell_escape(peer))
            if ip6 and #ip6 > 0 then cmd = cmd .. " " .. systools_common.shell_escape(ip6) end
            if prefix and #prefix > 0 then cmd = cmd .. " " .. systools_common.shell_escape(prefix) end
            if tid and #tid > 0 then cmd = cmd .. " " .. systools_common.shell_escape(tid) end
            if user and #user > 0 then cmd = cmd .. " " .. systools_common.shell_escape(user) end
            if pass and #pass > 0 then cmd = cmd .. " " .. systools_common.shell_escape(pass) end
            luci.sys.call(cmd .. " >/dev/null 2>&1 &")
        else
            m.message = translate("Please enter tunnel server address")
            return
        end
    elseif mode == "relay" then
        luci.sys.call("/usr/libexec/systools/ipv6.sh relay >/dev/null 2>&1 &")
    elseif mode == "disabled" then
        luci.sys.call("/usr/libexec/systools/ipv6.sh disabled >/dev/null 2>&1 &")
    end

    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "ipv6"))
end

-- 恢复按钮
btn_restore = s4:option(Button, "_restore", translate("Restore Previous Configuration"))
btn_restore.inputtitle = translate("Restore")
btn_restore.inputstyle = "reset"
btn_restore.description = translate("Restore from the most recent backup.")
function btn_restore.write(self, section)
    luci.sys.call("/usr/libexec/systools/ipv6.sh restore >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "ipv6"))
end

return m
