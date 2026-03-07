-- Easy MWAN3 Configurator (v2.1)
-- Copyright (C) 2024 PengCong226
-- Licensed under MIT

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local m = Map("easy_mwan3", translate("Easy MWAN3 Configurator"),
    translate("A simplified, intelligent interface for configuring MWAN3 Load Balancing."))

-- 检查 mwan3 服务状态
local mwan3_status = sys.call("/etc/init.d/mwan3 enabled >/dev/null 2>&1")
if mwan3_status ~= 0 then
    m.message = translate("Warning: MWAN3 service is not enabled!")
end

-- 获取 WAN 接口列表（改进版）
local function get_wan_interfaces()
    local interfaces = {}
    
    -- 方法1: 从 UCI 配置读取
    uci:foreach("network", "interface", function(s)
        local name = s[".name"]
        local proto = s.proto or ""
        
        -- 排除 lo 和 lan 接口
        if name ~= "lo" and name ~= "lan" then
            -- 检查是否是 WAN 类型接口
            if name:match("^wan") or 
               proto:match("^ppp") or 
               proto:match("^dhcp") or
               proto:match("^static") then
                interfaces[#interfaces+1] = name
            end
        end
    end)
    
    -- 方法2: 从网络设备读取（备用）
    if #interfaces == 0 then
        for _, iface in ipairs(sys.net.devices()) do
            if iface ~= "lo" and not iface:match("^br") and not iface:match("^eth[0-9]+%.") then
                if iface:match("^eth") or iface:match("^wan") or 
                   iface:match("^pppoe") or iface:match("^vlan") then
                    interfaces[#interfaces+1] = iface
                end
            end
        end
    end
    
    return interfaces
end

-- 安全读取 DHCP 租约（修复命令注入风险）
local function get_dhcp_leases()
    local leases = {}
    local content = fs.readfile("/tmp/dhcp.leases")
    
    if content then
        for line in content:gmatch("[^\r\n]+") do
            -- 支持多种格式
            local mac, ip, name = line:match("(%S+)%s+(%S+)%s+(%S+)")
            if mac and ip then
                leases[#leases+1] = {
                    mac = mac,
                    ip = ip,
                    name = name or "Unknown"
                }
            end
        end
    end
    
    return leases
end

-- 全局设置
local s = m:section(TypedSection, "global", translate("Global Settings"))
s.anonymous = true

local e = s:option(Flag, "enabled", translate("Enable Easy MWAN3"))
e.rmempty = false
e.default = "0"

-- 策略模式
local mode = s:option(ListValue, "mode", translate("Load Balancing Mode"))
mode:value("balance", translate("Balanced (Weighted)"))
mode:value("failover", translate("Failover (Active/Backup)"))
mode.default = "balance"
mode.description = translate("Balance mode distributes traffic across all interfaces. Failover mode uses primary interface and switches to backup on failure.")

-- 成员接口
local wan_ifaces = get_wan_interfaces()
local members = s:option(MultiValue, "members", translate("Participating Interfaces"))
members.description = translate("Select WAN interfaces to participate in load balancing.")

for _, iface in ipairs(wan_ifaces) do
    members:value(iface, iface:upper())
end
members.widget = "checkbox"

-- 高级策略规则
local s2 = m:section(TypedSection, "rule", translate("Advanced Device Policies"))
s2.template = "cbi/tblsection"
s2.anonymous = true
s2.addremove = true
s2.description = translate("Define custom routing policies for specific devices.")

-- 源 IP/设备
local src = s2:option(Value, "src_ip", translate("Source IP/Device"))
src.datatype = "ipaddr"
src.description = translate("IP address or device to apply policy to.")

-- 添加 DHCP 租约选项
local leases = get_dhcp_leases()
if #leases > 0 then
    for _, lease in ipairs(leases) do
        if lease.name and lease.name ~= "Unknown" then
            src:value(lease.ip, lease.name .. " (" .. lease.ip .. ")")
        end
    end
end

-- 策略选择
local policy = s2:option(ListValue, "policy", translate("Policy"))
policy:value("default", translate("Default (Follow Global)"))
policy:value("wan_only", translate("Force WAN Only"))
policy:value("wan2_only", translate("Force WAN2 Only"))
policy.description = translate("Select routing policy for this device.")

-- 备注
local comment = s2:option(Value, "comment", translate("Comment"))
comment.optional = true
comment.placeholder = translate("Optional description")

return m
