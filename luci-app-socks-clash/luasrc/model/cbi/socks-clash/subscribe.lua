local m, s, o

m = Map("socks-clash", "配置订阅",
    "管理配置订阅。您可以从代理服务商添加订阅链接，并使用过滤器筛选节点。")

-- Subscription List
s = m:section(TypedSection, "config_subscribe", "订阅列表")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", "启用")
o.default = "1"
o.rmempty = false
o.width = "5%"

o = s:option(Value, "name", "名称")
o.rmempty = false
o.placeholder = "订阅名称"
o.width = "15%"

o = s:option(Value, "address", "订阅地址")
o.rmempty = false
o.placeholder = "https://example.com/subscribe"
o.width = "35%"

o = s:option(ListValue, "sub_ua", "用户代理")
o:value("Clash", "Clash")
o:value("ClashMeta", "Clash.Meta")
o:value("ClashForAndroid", "ClashForAndroid")
o:value("V2RayN", "V2RayN")
o:value("Shadowrocket", "Shadowrocket")
o:value("Quantumult", "Quantumult")
o:value("Surge", "Surge")
o.default = "ClashMeta"
o.width = "10%"

o = s:option(ListValue, "auto_update", "自动更新")
o:value("0", "禁用")
o:value("1", "启用")
o.default = "0"
o.width = "8%"

o = s:option(ListValue, "auto_update_time", "更新时间")
o:value("0 */1 * * *", "每小时")
o:value("0 */6 * * *", "每 6 小时")
o:value("0 */12 * * *", "每 12 小时")
o:value("0 6 * * *", "每天 6:00")
o:value("0 6 * * 0", "每周日 6:00")
o.default = "0 6 * * *"
o:depends("auto_update", "1")
o.width = "12%"

-- Subscription Filter Section
s = m:section(TypedSection, "config_subscribe", "订阅过滤器")
s.anonymous = true
s.addremove = false

o = s:option(Value, "keyword_include", "包含关键词",
    "只保留名称包含这些关键词的节点，多个关键词用竖线 | 分隔（如：香港|台湾|新加坡）")
o.placeholder = "香港|台湾|新加坡"

o = s:option(Value, "keyword_exclude", "排除关键词",
    "移除名称包含这些关键词的节点，多个关键词用竖线 | 分隔（如：过期|剩余|官网）")
o.placeholder = "过期|剩余|官网"

o = s:option(MultiValue, "type_filter", "节点类型过滤",
    "只保留选中类型的节点")
o:value("ss", "Shadowsocks")
o:value("ssr", "ShadowsocksR")
o:value("vmess", "VMess")
o:value("vless", "VLESS")
o:value("trojan", "Trojan")
o:value("hysteria", "Hysteria")
o:value("hysteria2", "Hysteria2")
o:value("tuic", "TUIC")
o.widget = "checkbox"

o = s:option(Flag, "remove_duplicate", "移除重复节点",
    "根据节点名称自动移除重复的节点（保留第一个）")
o.default = "0"

o = s:option(Value, "max_nodes", "节点数量限制",
    "限制保留的节点数量，0 表示不限制")
o.default = "0"
o.placeholder = "0"
o.datatype = "uinteger"

-- Subscription Info Section
s = m:section(TypedSection, "config_subscribe", "订阅信息")
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "sub_info", "流量信息",
    "订阅流量使用情况（如果订阅商支持）")

-- Manual Update Section
s = m:section(TypedSection, "socks-clash", "手动更新")
s.anonymous = true
s.addremove = false

o = s:option(Button, "update_now", "立即更新所有订阅")
o.inputtitle = "开始更新"
o.inputstyle = "apply"
o.write = function()
    luci.sys.call("/usr/share/socks-clash/update_subscribe.sh >/dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "socks-clash", "log"))
end

o = s:option(Button, "clear_nodes", "清除所有节点")
o.inputtitle = "清除节点"
o.inputstyle = "reset"
o.write = function()
    luci.sys.call("rm -f /etc/socks-clash/config/*.yaml 2>/dev/null")
    luci.sys.call("uci -q delete socks-clash.@servers[0]")
    luci.sys.call("uci commit socks-clash")
end

return m
