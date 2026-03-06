local m, s, o

m = Map("socks-clash", "路由规则",
    "配置代理路由规则。")

s = m:section(TypedSection, "rules", "快捷规则")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", "启用规则")
o.default = "1"

-- Predefined rule sets
s = m:section(TypedSection, "socks-clash", "预设规则")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "geoip_cn_direct", "中国 IP 直连")
o.default = "1"
o.description = "中国 IP 直连不走代理"

o = s:option(Flag, "private_direct", "内网 IP 直连")
o.default = "1"
o.description = "内网/局域网 IP 直连"

o = s:option(ListValue, "final_rule", "最终规则")
o:value("PROXY", "代理")
o:value("DIRECT", "直连")
o:value("REJECT", "拒绝")
o.default = "PROXY"
o.description = "未匹配流量的默认操作"

-- Custom Rules
s = m:section(TypedSection, "custom_rule", "自定义规则")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"

o = s:option(ListValue, "type", "类型")
o:value("DOMAIN", "DOMAIN")
o:value("DOMAIN-SUFFIX", "DOMAIN-SUFFIX")
o:value("DOMAIN-KEYWORD", "DOMAIN-KEYWORD")
o:value("IP-CIDR", "IP-CIDR")
o:value("IP-CIDR6", "IP-CIDR6")
o:value("GEOIP", "GEOIP")
o:value("PROCESS-NAME", "PROCESS-NAME")
o.default = "DOMAIN-SUFFIX"

o = s:option(Value, "value", "值")
o.rmempty = false
o.placeholder = "例如：google.com, CN, 192.168.0.0/16"

o = s:option(ListValue, "action", "动作")
o:value("PROXY", "代理")
o:value("DIRECT", "直连")
o:value("REJECT", "拒绝")
o.default = "PROXY"

o = s:option(Flag, "enabled", "启用")
o.default = "1"

return m
