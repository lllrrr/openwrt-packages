-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"

m = Map("systools", translate("LAN IP Settings"),
    translate("Modify the router's LAN IP address. After modification, you need to reconnect with the new address."))

-- 当前状态
s = m:section(TypedSection, "global", translate("Current LAN Configuration"))
s.anonymous = true

-- 获取当前LAN IP和子网掩码
local current_ip = "N/A"
local current_mask = "N/A"
local status_output = luci.sys.exec("/usr/libexec/systools/lan_ip.sh status 2>/dev/null")
for line in status_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "ipaddr" then current_ip = value end
    if key == "netmask" then current_mask = value end
end

o = s:option(DummyValue, "_current_ip", translate("Current LAN IP"))
o.value = current_ip

o = s:option(DummyValue, "_current_mask", translate("Current Subnet Mask"))
o.value = current_mask

-- 修改设置
s2 = m:section(TypedSection, "global", translate("New LAN Configuration"))
s2.anonymous = true

o = s2:option(Value, "new_ipaddr", translate("New LAN IP Address"))
o.datatype = "ip4addr"
o.placeholder = "192.168.1.1"
o.rmempty = false
o.description = translate("Enter the new IP address for the LAN interface. Cannot be network address or broadcast address.")

o = s2:option(Value, "new_netmask", translate("Subnet Mask"))
o.datatype = "ip4addr"
o.default = "255.255.255.0"
o.placeholder = "255.255.255.0"
o.rmempty = false
o.description = translate("Usually 255.255.255.0 for home networks")

-- 操作按钮
s3 = m:section(TypedSection, "global", translate("Operations"))
s3.anonymous = true

btn_apply = s3:option(Button, "_apply", translate("Apply Changes"))
btn_apply.inputtitle = translate("Apply")
btn_apply.inputstyle = "apply"
btn_apply.description = translate("Click to apply the new LAN IP. Network will restart and you will need to reconnect.")

function btn_apply.write(self, section)
    local new_ip = m:formvalue("cbid.systools.global.new_ipaddr")
    local new_mask = m:formvalue("cbid.systools.global.new_netmask")
    
    if new_ip and #new_ip > 0 then
        local mask_arg = new_mask and #new_mask > 0 and " " .. systools_common.shell_escape(new_mask) or ""
        local cmd = string.format("/usr/libexec/systools/lan_ip.sh apply %s%s >/dev/null 2>&1 &",
            systools_common.shell_escape(new_ip), mask_arg)
        luci.sys.call(cmd)
        
        -- 提示用户需要用新地址重新访问
        m.message = translate("Settings are being applied. Please wait 10-20 seconds, then access the router with the new IP address.")
    else
        m.message = translate("Please enter a valid IP address")
    end
end

-- 重要提示
s4 = m:section(TypedSection, "global", translate("Important Notes"))
s4.anonymous = true

o = s4:option(DummyValue, "_tip1")
o.value = "• " .. translate("After applying, the network will restart and you will be temporarily disconnected")
o.rawhtml = true

o = s4:option(DummyValue, "_tip2")
o.value = "• " .. translate("You must access the router management page using the new IP address after modification")
o.rawhtml = true

o = s4:option(DummyValue, "_tip3")
o.value = "• " .. translate("Make sure your computer is set to the same subnet, otherwise you won't be able to access")
o.rawhtml = true

o = s4:option(DummyValue, "_tip4")
o.value = "• " .. translate("DHCP address pool start offset will be automatically adjusted to match the new network segment")
o.rawhtml = true

o = s4:option(DummyValue, "_tip5")
o.value = "• " .. translate("Automatically detects WAN/LAN subnet conflicts to prevent routing failures")
o.rawhtml = true

-- 故障恢复提示
s5 = m:section(TypedSection, "global", translate("Troubleshooting"))
s5.anonymous = true

o = s5:option(DummyValue, "_recovery1")
o.value = "• " .. translate("If you cannot access after modification, check your computer's IP settings")
o.rawhtml = true

o = s5:option(DummyValue, "_recovery2")
o.value = "• " .. translate("If you forget the new IP, you can check the gateway address on your computer")
o.rawhtml = true

o = s5:option(DummyValue, "_recovery3")
o.value = "• " .. translate("In case of configuration error, press the reset button on the router to restore factory settings")
o.rawhtml = true

o = s5:option(DummyValue, "_recovery4")
o.value = "• " .. translate("Each modification automatically backs up the configuration, which can be found in /etc/config/")
o.rawhtml = true

return m
