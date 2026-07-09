-- Copyright 2024 System Tools Project
-- Licensed under the MIT License

local m, s, o
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"

m = Map("systools", translate("设备管理"), translate("管理内网连接的设备，查看设备列表、修改备注名、绑定静态IP等。"))

-- 当前状态显示
s = m:section(TypedSection, "device_manager", translate("设备列表"))
s.anonymous = true
s.addremove = false

-- 设备列表表格
local devices = {}

-- 从 DHCP 租约读取设备
local leases = luci.sys.net.arptable() or {}
for _, lease in ipairs(leases) do
    local dev = {
        ip = lease["IP address"] or "",
        mac = lease["HW address"] or "",
        hostname = lease["Hostname"] or translate("未知设备"),
        interface = lease["Device"] or "br-lan",
        static = false
    }
    
    -- 检查是否有静态绑定
    local static_ip = uci:get("dhcp", "@host[0]", "ip")
    if static_ip and static_ip == dev.ip then
        dev.static = true
    end
    
    -- 检查是否有备注名
    local nickname = uci:get("systools", "device_" .. dev.mac:gsub(":", "_"), "nickname")
    if nickname then
        dev.nickname = nickname
    else
        dev.nickname = dev.hostname
    end
    
    table.insert(devices, dev)
end

-- 显示设备数量
o = s:option(DummyValue, "device_count", translate("设备总数"))
o.value = #devices .. " " .. translate("台")

-- 设备列表表格
local tbl = s:option(Table, "device_list", translate("已连接设备"))
tbl.template = "cbi/tblsection"
tbl.widget = "tblsection"
tbl.addremove = false
tbl.anonymous = true

-- IP 地址
local ip_col = tbl:option(DummyValue, "ip", translate("IP 地址"))
ip_col.forcewrite = true

-- MAC 地址
local mac_col = tbl:option(DummyValue, "mac", translate("MAC 地址"))
mac_col.forcewrite = true

-- 设备名称
local name_col = tbl:option(DummyValue, "nickname", translate("设备名称"))
name_col.forcewrite = true

-- 连接接口
local iface_col = tbl:option(DummyValue, "interface", translate("接口"))
iface_col.forcewrite = true

-- 是否静态绑定
local static_col = tbl:option(DummyValue, "static", translate("静态绑定"))
static_col.forcewrite = true
static_col.value = function(self, section)
    local val = self.map:get(section, "static")
    if val == "1" or val == true then
        return translate("是")
    else
        return translate("否")
    end
end

-- 操作按钮
local edit_col = tbl:option(Button, "edit", translate("编辑"))
edit_col.inputtitle = translate("编辑")
edit_col.inputstyle = "apply"
edit_col.forcewrite = true
edit_col.write = function(self, section)
    -- 跳转到编辑页面
    local mac = self.map:get(section, "mac")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "device_manager", "edit", mac:gsub(":", "_")))
end

-- 添加设备备注名
s = m:section(NamedSection, "device_nickname", "systools", translate("修改设备备注名"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "device_mac", translate("选择设备"))
for _, dev in ipairs(devices) do
    o:value(dev.mac, dev.nickname .. " (" .. dev.ip .. ")")
end
o.rmempty = false

o = s:option(Value, "nickname", translate("备注名称"))
o.rmempty = false
o.description = translate("给设备起一个好记的名字，比如\"爸爸的手机\"、\"客厅电视\"")

-- 静态 IP 绑定
s = m:section(NamedSection, "static_ip", "systools", translate("静态 IP 绑定"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "device_mac", translate("选择设备"))
for _, dev in ipairs(devices) do
    o:value(dev.mac, dev.nickname .. " (" .. dev.ip .. ")")
end
o.rmempty = false

o = s:option(Value, "static_ip", translate("绑定 IP 地址"))
o.datatype = "ip4addr"
o.rmempty = false
o.description = translate("设置后该设备连接网络时将永远获取这个 IP 地址")

o = s:option(Flag, "enable_static", translate("启用静态绑定"))
o.default = "0"
o.rmempty = false

-- 应用按钮
s = m:section(NamedSection, "apply", "systools", translate("应用配置"))
s.anonymous = true

o = s:option(Button, "apply_btn", translate("应用配置"))
o.inputtitle = translate("应用配置")
o.inputstyle = "apply"
o.write = function()
    -- 执行后端脚本应用配置
    luci.sys.call("/usr/libexec/systools/device_manager.sh apply >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "device_manager"))
end

-- 回滚按钮
o = s:option(Button, "rollback_btn", translate("回滚配置"))
o.inputtitle = translate("回滚配置")
o.inputstyle = "reset"
o.write = function()
    -- 执行后端脚本回滚配置
    luci.sys.call("/usr/libexec/systools/device_manager.sh rollback >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "systools", "wizard", "device_manager"))
end

return m
