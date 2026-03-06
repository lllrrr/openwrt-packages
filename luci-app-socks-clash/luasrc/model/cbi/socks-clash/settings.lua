local m, s, o

m = Map("socks-clash", "SocksClash 设置",
    "配置 SocksClash 代理设置。这是一个简化的仅代理模式，不包含 DNS 劫持或透明代理功能。")

s = m:section(TypedSection, "socks-clash", "常规设置")
s.anonymous = true
s.addremove = false

-- Enable
o = s:option(Flag, "enable", "启用")
o.rmempty = false
o.default = "0"
o.enabled = "1"
o.disabled = "0"

-- Log Level
o = s:option(ListValue, "log_level", "日志级别")
o:value("silent", "静默")
o:value("error", "错误")
o:value("warning", "警告")
o:value("info", "信息")
o:value("debug", "调试")
o.default = "info"

-- Proxy Mode
o = s:option(ListValue, "mode", "代理模式")
o:value("rule", "规则模式")
o:value("global", "全局模式")
o:value("direct", "直连模式")
o.default = "rule"
o.description = "规则：基于规则路由 | 全局：所有流量走代理 | 直连：所有流量直连"

-- Allow LAN
o = s:option(Flag, "allow_lan", "允许局域网")
o.default = "1"
o.description = "允许局域网设备连接"

-- Bind Address
o = s:option(Value, "bind_address", "绑定地址")
o.default = "*"
o.placeholder = "*"
o.description = "'*' 表示所有接口，或指定一个 IP 地址"

-- IPv6
o = s:option(Flag, "ipv6", "启用 IPv6")
o.default = "0"

s = m:section(TypedSection, "socks-clash", "仪表盘设置")
s.anonymous = true
s.addremove = false

-- External Controller Port
o = s:option(Value, "cn_port", "仪表盘端口")
o.datatype = "port"
o.default = "9090"
o.description = "用于访问仪表盘的外部控制器端口"

-- Dashboard Password
o = s:option(Value, "dashboard_password", "仪表盘密码")
o.password = true
o.placeholder = "留空则无需认证"

return m
