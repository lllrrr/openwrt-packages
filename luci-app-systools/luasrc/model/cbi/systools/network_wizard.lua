-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

-- Shell 转义函数，防止命令注入
local function shell_escape(str)
    if not str then return "" end
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

m = Map("systools", translate("Internet Setup Wizard"),
    translate("Step-by-step guide to configure your network. Suitable for beginners."))

s = m:section(TypedSection, "wizard", translate("Current Network Status"))
s.anonymous = true

-- 连接状态
local connected = "no"
local wan_proto = "unknown"
local lan_ip = "N/A"

local status_output = luci.sys.exec("/usr/libexec/systools/network_wizard.sh status 2>/dev/null")
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "connected" then connected = value end
    if key == "wan_proto" then wan_proto = value end
    if key == "lan_ip" then lan_ip = value end
end

o = s:option(DummyValue, "_status", translate("Connection Status"))
if connected == "yes" then
    o.value = '<span style="color:green;font-weight:bold">' .. translate("Connected") .. '</span>'
else
    o.value = '<span style="color:red;font-weight:bold">' .. translate("Not Connected") .. '</span>'
end
o.rawhtml = true

o = s:option(DummyValue, "_wan_type", translate("WAN Type"))
o.value = wan_proto:upper()

o = s:option(DummyValue, "_lan_ip", translate("LAN IP Address"))
o.value = lan_ip

-- 上网方式选择
s2 = m:section(TypedSection, "wizard", translate("Select Connection Type"))
s2.anonymous = true

o = s2:option(ListValue, "connection_type", translate("Connection Type"),
    translate("Select your internet connection type"))
o:value("dhcp", translate("DHCP - Auto Obtain IP"))
o:value("pppoe", translate("PPPoE - Dial-up"))
o:value("static", translate("Static IP"))
o.default = "dhcp"
o.rmempty = false

-- PPPoE 配置
s3 = m:section(TypedSection, "wizard", translate("PPPoE Configuration"))
s3.anonymous = true
s3:depends("connection_type", "pppoe")

o = s3:option(Value, "pppoe_username", translate("Username"))
o.placeholder = "your_username"
o.datatype = "string"

o = s3:option(Value, "pppoe_password", translate("Password"))
o.placeholder = "your_password"
o.password = true
o.datatype = "string"

-- 静态 IP 配置
s4 = m:section(TypedSection, "wizard", translate("Static IP Configuration"))
s4.anonymous = true
s4:depends("connection_type", "static")

o = s4:option(Value, "static_ip", translate("IP Address"))
o.datatype = "ip4addr"

o = s4:option(Value, "static_gateway", translate("Gateway"))
o.datatype = "ip4addr"

o = s4:option(Value, "static_netmask", translate("Subnet Mask"))
o.datatype = "ip4addr"
o.default = "255.255.255.0"

o = s4:option(Value, "static_dns", translate("DNS Server"))
o.datatype = "ip4addr"
o.optional = true

-- 高级设置（所有模式通用）
s_advanced = m:section(TypedSection, "wizard", translate("Advanced Settings"))
s_advanced.anonymous = true
s_advanced.addremove = false

-- MAC 地址克隆
o = s_advanced:option(Value, "wan_mac", translate("WAN MAC Address"),
    translate("Customize WAN MAC address. Leave blank to use default."))
o.datatype = "macaddr"
o.optional = true
o.placeholder = "AA:BB:CC:DD:EE:FF"
o.description = translate("Clone MAC address for ISP binding scenarios")

-- MTU 设置
o = s_advanced:option(Value, "wan_mtu", translate("WAN MTU"),
    translate("Maximum Transmission Unit. Default is 1500, PPPoE recommended 1492."))
o.datatype = "range(576, 1500)"
o.optional = true
o.default = "1500"
o.placeholder = "1500"

-- DNS 自定义
o = s_advanced:option(Value, "dns_primary", translate("Primary DNS"),
    translate("Primary DNS server address"))
o.datatype = "ip4addr"
o.optional = true
o.placeholder = "114.114.114.114"

o = s_advanced:option(Value, "dns_secondary", translate("Secondary DNS"),
    translate("Secondary DNS server address (optional)"))
o.datatype = "ip4addr"
o.optional = true
o.placeholder = "223.5.5.5"

-- 操作按钮
s5 = m:section(TypedSection, "wizard", translate("Operations"))
s5.anonymous = true

-- 应用配置按钮
btn_apply = s5:option(Button, "_apply", translate("Apply Configuration"))
btn_apply.inputtitle = translate("Apply Configuration")
btn_apply.inputstyle = "apply"
btn_apply.description = translate("Click to apply the network configuration. The current configuration will be backed up automatically.")
function btn_apply.write(self, section)
    local conn_type = m:formvalue("cbid.systools.wizard.connection_type")
    local wan_mac = m:formvalue("cbid.systools.wizard.wan_mac")
    local wan_mtu = m:formvalue("cbid.systools.wizard.wan_mtu")
    local dns_primary = m:formvalue("cbid.systools.wizard.dns_primary")
    local dns_secondary = m:formvalue("cbid.systools.wizard.dns_secondary")

    -- 构建高级参数
    local advanced_args = ""
    if wan_mac and #wan_mac > 0 then
        advanced_args = advanced_args .. " mac=" .. shell_escape(wan_mac)
    end
    if wan_mtu and #wan_mtu > 0 then
        advanced_args = advanced_args .. " mtu=" .. shell_escape(wan_mtu)
    end
    if dns_primary and #dns_primary > 0 then
        advanced_args = advanced_args .. " dns1=" .. shell_escape(dns_primary)
    end
    if dns_secondary and #dns_secondary > 0 then
        advanced_args = advanced_args .. " dns2=" .. shell_escape(dns_secondary)
    end

    if conn_type == "pppoe" then
        local user = m:formvalue("cbid.systools.wizard.pppoe_username")
        local pass = m:formvalue("cbid.systools.wizard.pppoe_password")
        if user and pass and #user > 0 and #pass > 0 then
            local cmd = string.format("/usr/libexec/systools/network_wizard.sh pppoe %s %s%s >/dev/null 2>&1 &",
                shell_escape(user), shell_escape(pass), advanced_args)
            luci.sys.call(cmd)
            luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "wizard"))
        else
            m.message = translate("Please enter username and password")
        end
    elseif conn_type == "dhcp" then
        luci.sys.call("/usr/libexec/systools/network_wizard.sh dhcp" .. advanced_args .. " >/dev/null 2>&1 &")
        luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "wizard"))
    elseif conn_type == "static" then
        local ip = m:formvalue("cbid.systools.wizard.static_ip")
        local gw = m:formvalue("cbid.systools.wizard.static_gateway")
        local mask = m:formvalue("cbid.systools.wizard.static_netmask")
        local dns = m:formvalue("cbid.systools.wizard.static_dns")
        if ip and gw and #ip > 0 and #gw > 0 then
            local cmd = string.format("/usr/libexec/systools/network_wizard.sh static %s %s",
                shell_escape(ip), shell_escape(gw))
            if mask and #mask > 0 then
                cmd = cmd .. " " .. shell_escape(mask)
            end
            if dns and #dns > 0 then
                cmd = cmd .. " " .. shell_escape(dns)
            end
            cmd = cmd .. advanced_args
            luci.sys.call(cmd .. " >/dev/null 2>&1 &")
            luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "wizard"))
        else
            m.message = translate("Please enter IP address and gateway")
        end
    end
end

-- 恢复按钮
btn_restore = s5:option(Button, "_restore", translate("Restore Previous Configuration"))
btn_restore.inputtitle = translate("Restore")
btn_restore.inputstyle = "reset"
btn_restore.description = translate("Restore from the most recent backup.")
function btn_restore.write(self, section)
    luci.sys.call("/usr/libexec/systools/network_wizard.sh restore >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "wizard"))
end

-- 提示信息
s6 = m:section(TypedSection, "wizard", translate("Tips"))
s6.anonymous = true

o = s6:option(DummyValue, "_tip1")
o.value = "• " .. translate("Configuration is automatically backed up before applying")
o.rawhtml = true

o = s6:option(DummyValue, "_tip2")
o.value = "• " .. translate("If there is a problem, you can click 'Restore Previous Configuration'")
o.rawhtml = true

o = s6:option(DummyValue, "_tip3")
o.value = "• " .. translate("After applying, the network will restart and may be interrupted for a few seconds")
o.rawhtml = true

o = s6:option(DummyValue, "_tip4")
o.value = "• " .. translate("If you are not sure which type to choose, try DHCP first")
o.rawhtml = true

return m
