-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

m = Map("systools", translate("旁路由模式"),
    translate("一键切换正常路由模式和旁路由模式。旁路由模式下，路由器作为旁路网关工作，可用于代理和特殊网络处理。"))

s = m:section(TypedSection, "side_route", translate("当前状态"))
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
o = s:option(DummyValue, "_mode", translate("当前模式"))
if mode == "side_route" then
    o.value = '<span style="color:orange;font-weight:bold">' .. translate("旁路由模式") .. '</span>'
else
    o.value = '<span style="color:green;font-weight:bold">' .. translate("正常路由模式") .. '</span>'
end
o.rawhtml = true

-- LAN IP
o = s:option(DummyValue, "_lan_ip", translate("LAN 口 IP 地址"))
o.value = lan_ip

-- 默认网关
o = s:option(DummyValue, "_gateway", translate("默认网关"))
o.value = gateway

-- DHCP 状态
o = s:option(DummyValue, "_dhcp", translate("DHCP 服务器"))
if dhcp_enabled == "yes" then
    o.value = '<span style="color:green">' .. translate("已启用") .. '</span>'
else
    o.value = '<span style="color:red">' .. translate("已禁用") .. '</span>'
end
o.rawhtml = true

-- 操作按钮
s2 = m:section(TypedSection, "side_route", translate("操作"))
s2.anonymous = true

-- 切换到旁路由模式
btn_enable = s2:option(Button, "_enable", translate("切换到旁路由模式"))
btn_enable.inputtitle = translate("启用旁路由")
btn_enable.inputstyle = "apply"
btn_enable.description = translate("自动检测网络环境并切换到旁路由模式，路由器将作为旁路网关工作。")
function btn_enable.write(self, section)
    luci.sys.call("/usr/libexec/systools/side_route.sh enable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "side_route"))
end

-- 恢复正常模式
btn_disable = s2:option(Button, "_disable", translate("恢复正常模式"))
btn_disable.inputtitle = translate("恢复正常模式")
btn_disable.inputstyle = "reset"
btn_disable.description = translate("从备份恢复到正常路由模式。")
function btn_disable.write(self, section)
    luci.sys.call("/usr/libexec/systools/side_route.sh disable >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "network", "side_route"))
end

-- 重要提示
s3 = m:section(TypedSection, "side_route", translate("重要提示"))
s3.anonymous = true

o = s3:option(DummyValue, "_warning")
o.value = '<div style="background-color: #fff3cd; border: 1px solid #ffeeba; padding: 15px; border-radius: 4px; color: #856404;"><strong>' .. translate("警告") .. '：</strong><ul style="margin: 10px 0; padding-left: 20px;"><li>' .. translate("切换模式会导致网络中断几秒钟") .. '</li><li>' .. translate("旁路由模式下，DHCP 服务器将被关闭") .. '</li><li>' .. translate("设备需要手动设置网关为本路由器 IP 才能使用旁路由") .. '</li><li>' .. translate("或者在主路由的 DHCP 设置中指定网关") .. '</li><li>' .. translate("切换前自动备份配置，出现问题可随时恢复") .. '</li></ul></div>'
o.rawhtml = true

return m
