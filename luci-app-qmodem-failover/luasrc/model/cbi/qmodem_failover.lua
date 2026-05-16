--[[
  qmodem_failover.lua - LuCI CBI 配置模型
  位置: /usr/lib/lua/luci/model/cbi/qmodem_failover.lua
  功能: 生成 Web 配置表单，读写 /etc/config/qmodem_failover
--]]

local m, s, o
local sys = require "luci.sys"

-- ─────────────────────────────────────────────
-- Map: 绑定到 UCI 配置文件 qmodem_failover
-- ─────────────────────────────────────────────
m = Map("qmodem_failover",
    translate("QMODEM 故障切换"),
    translate("有线 WAN 网络故障时自动切换至 QMODEM 移动网络，恢复后自动切回，全程无感知。")
)

-- 提交时自动重启服务
m.on_after_commit = function(self)
    sys.call("/etc/init.d/qmodem-failover restart >/dev/null 2>&1 &")
end

-- ─────────────────────────────────────────────
-- Section 1: 基本设置
-- ─────────────────────────────────────────────
s = m:section(TypedSection, "general", translate("基本设置"))
s.anonymous = true
s.addremove = false

-- 启用开关
o = s:option(Flag, "enabled", translate("启用插件"))
o.rmempty  = false
o.default  = "1"

-- WAN 接口
o = s:option(Value, "wan_iface", translate("有线 WAN 接口"),
    translate("通常为 eth0 或 wan，可通过 <code>ip link show</code> 查看"))
o.default    = "eth0"
o.rmempty    = false
o.datatype   = "string"
-- 下拉候选（可手动输入）
local ifaces = sys.exec("ip -o link show | awk -F': ' '{print $2}' | grep -v lo")
for iface in ifaces:gmatch("[^\n]+") do
    o:value(iface, iface)
end

-- LTE 接口
o = s:option(Value, "lte_iface", translate("QMODEM 接口"),
    translate("USB 网卡通常为 usb0，PPP 拨号为 ppp0"))
o.default  = "usb0"
o.rmempty  = false
o:value("usb0",  "usb0  (USB 网卡 / RNDIS)")
o:value("usb1",  "usb1")
o:value("ppp0",  "ppp0  (PPP 拨号)")
o:value("wwan0", "wwan0 (ModemManager)")

-- 检测间隔
o = s:option(Value, "check_interval",
    translate("检测间隔（秒）"),
    translate("每隔多少秒发起一次 WAN 检测，越小响应越快但 CPU 占用略高，建议 3~5"))
o.datatype = "range(1, 30)"
o.default  = "3"

-- 故障判定次数
o = s:option(Value, "fail_threshold",
    translate("故障判定次数"),
    translate("连续失败多少次后判定 WAN 故障并切换至 LTE，建议 3（约 9 秒）"))
o.datatype = "range(1, 10)"
o.default  = "3"

-- 恢复判定次数
o = s:option(Value, "success_threshold",
    translate("恢复判定次数"),
    translate("切换到 LTE 后，连续成功多少次才切回 WAN（防止来回抖动），建议 5"))
o.datatype = "range(1, 10)"
o.default  = "5"

-- Ping 超时
o = s:option(Value, "ping_timeout",
    translate("Ping 超时（秒）"),
    translate("单次 Ping 的等待超时，建议 2"))
o.datatype = "range(1, 10)"
o.default  = "2"

-- ─────────────────────────────────────────────
-- Section 2: 高级路由设置（折叠）
-- ─────────────────────────────────────────────
s2 = m:section(TypedSection, "general", translate("高级路由设置"))
s2.anonymous  = true
s2.addremove  = false
s2.collapsed  = true

o = s2:option(Value, "metric_wan",
    translate("WAN 路由 Metric"),
    translate("有线 WAN 的路由优先级，数值越小越优先，默认 10"))
o.datatype = "range(1, 999)"
o.default  = "10"

o = s2:option(Value, "metric_lte",
    translate("LTE 路由 Metric（备用时）"),
    translate("LTE 处于备用状态时的路由 Metric，应大于 WAN，默认 100"))
o.datatype = "range(1, 999)"
o.default  = "100"

-- ─────────────────────────────────────────────
-- Section 3: 检测目标
-- ─────────────────────────────────────────────
s3 = m:section(TypedSection, "hosts",
    translate("Ping 检测目标"),
    translate("WAN 检测时会依次 Ping 以下 IP，任意一个成功即认为 WAN 正常。建议保留多个备用目标。"))
s3.anonymous  = true
s3.addremove  = false

o = s3:option(DynamicList, "host", translate("目标 IP"))
o.datatype = "ipaddr"
o.default  = "223.5.5.5"

-- ─────────────────────────────────────────────
-- Section 4: 通知配置
-- ─────────────────────────────────────────────
s4 = m:section(TypedSection, "notify",
    translate("故障通知（可选）"),
    translate("网络切换时通过 Webhook 推送消息到钉钉/企业微信/飞书"))
s4.anonymous = true
s4.addremove = false

o = s4:option(Flag, "enabled", translate("启用通知"))
o.rmempty = false
o.default = "0"

o = s4:option(ListValue, "webhook_type", translate("通知平台"))
o:value("dingtalk", "钉钉机器人")
o:value("wecom",    "企业微信机器人")
o:value("feishu",   "飞书机器人")
o:value("custom",   "自定义 Webhook")
o.default = "dingtalk"
o:depends("enabled", "1")

o = s4:option(Value, "webhook_url",
    translate("Webhook URL"),
    translate("在对应平台创建群机器人后复制 Webhook 地址"))
o.password = false
o.rmempty  = true
o:depends("enabled", "1")

return m

