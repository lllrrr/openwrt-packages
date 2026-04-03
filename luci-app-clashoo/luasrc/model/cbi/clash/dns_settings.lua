local NXFS = require "nixio.fs"
local SYS  = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local uci  = require("luci.model.uci").cursor()

local function restart_if_running()
	if SYS.call("pidof mihomo >/dev/null || pidof clash-meta >/dev/null || pidof clash >/dev/null") == 0 then
		SYS.call("/etc/init.d/clash restart >/dev/null 2>&1 &")
		HTTP.redirect(DISP.build_url("admin", "services", "clash"))
	else
		HTTP.redirect(DISP.build_url("admin", "services", "clash", "dns_settings"))
	end
end

-- 第一块：基础DNS
m = Map("clash")
m.pageaction = false
s = m:section(TypedSection, "clash", "基础 DNS")
s.anonymous = true
s.addremove  = false
s.description = "配置 Clash/Mihomo 内置 DNS 解析行为"

o = s:option(Flag, "enable_dns", "启用内置 DNS")
o.default = 1
o.rmempty = false

o = s:option(Value, "listen_port", "DNS 监听端口")
o.default     = "5300"
o.datatype    = "port"
o.description = "Mihomo DNS 服务监听端口（listen: 0.0.0.0:PORT）"
o:depends("enable_dns", "1")

o = s:option(DynamicList, "default_nameserver", "引导 DNS")
o.description = "用于解析下方 DNS 服务器域名的纯 IP DNS，建议填国内可靠 DNS"
o:depends("enable_dns", "1")

o = s:option(ListValue, "enhanced_mode", "增强模式")
o:value("redir-host", "Redir-Host（真实 IP）")
o:value("fake-ip",    "Fake-IP（虚拟 IP，推荐）")
o.description = "Fake-IP 性能更好，配合透明代理效果最佳"
o:depends("enable_dns", "1")

o = s:option(Value, "fake_ip_range", "Fake-IP 地址段")
o.default     = "198.18.0.1/16"
o.description = "分配给域名的虚拟 IP 段，不要与局域网冲突"
o:depends("enhanced_mode", "fake-ip")

o = s:option(DynamicList, "fake_ip_filter", "Fake-IP 过滤列表")
o.default     = "*.lan"
o.description = "匹配的域名不使用 Fake-IP，直接返回真实 IP"
o:depends("enhanced_mode", "fake-ip")


-- 第二块：高级设置
s2 = m:section(TypedSection, "clash", "高级设置")
s2.anonymous = true
s2.addremove  = false

o = s2:option(ListValue, "dnsforwader", "DNS 转发（dnsmasq）")
o:value("0", "禁用")
o:value("1", "启用")
o.description = "在 DHCP/DNS 设置中添加自定义转发，将所有 DNS 流量导入 Clash"

o = s2:option(ListValue, "dnscache", "DNS 缓存")
o:value("0", "禁用")
o:value("1", "启用")

o = s2:option(ListValue, "access_control", "访问控制")
o:value("0", "禁用（全部代理）")
o:value("1", "白名单（仅代理指定 IP）")
o:value("2", "黑名单（排除指定 IP）")
o.description = "控制哪些局域网 IP 走透明代理，redir-host 和 fake-ip 模式均支持"

o = s2:option(DynamicList, "proxy_lan_ips", "白名单 IP")
o.datatype    = "ipaddr"
o.description = "仅这些 IP 的流量走代理"
luci.ip.neighbors({ family = 4 }, function(entry)
	if entry.reachable then o:value(entry.dest:string()) end
end)
o:depends("access_control", "1")

o = s2:option(DynamicList, "reject_lan_ips", "黑名单 IP")
o.datatype    = "ipaddr"
o.description = "这些 IP 的流量不走代理"
luci.ip.neighbors({ family = 4 }, function(entry)
	if entry.reachable then o:value(entry.dest:string()) end
end)
o:depends("access_control", "2")

o = s2:option(Button, "_apply2", "")
o.inputtitle = "保存并应用"
o.inputstyle = "apply"
o.write = function()
	m.uci:commit("clash")
	restart_if_running()
end

-- 第三块：上游DNS服务器
ss = m:section(TypedSection, "dnsservers", "上游 DNS 服务器")
ss.anonymous = true
ss.addremove  = true
ss.sortable   = false
ss.template   = "cbi/tblsection"
ss.rmempty    = false
ss.description = "国内推荐 nameserver：223.5.5.5（阿里）/ 119.29.29.29（腾讯）；海外 fallback：8.8.8.8（Google）/ 1.1.1.1（Cloudflare）"

o = ss:option(Flag, "enabled", "启用")
o.rmempty  = false
o.default  = o.enabled
o.cfgvalue = function(...) return Flag.cfgvalue(...) or "1" end

o = ss:option(ListValue, "ser_type", "类型")
o:value("nameserver", "主 DNS")
o:value("fallback",   "Fallback DNS")

o = ss:option(ListValue, "protocol", "协议")
o:value("none",     "无（直接 IP）")
o:value("tcp://",   "TCP")
o:value("udp://",   "UDP")
o:value("tls://",   "DNS-over-TLS")
o:value("https://", "DNS-over-HTTPS")

o = ss:option(Value, "ser_address", "地址")
o.placeholder = "例如: 223.5.5.5, 119.29.29.29, 8.8.8.8, 1.1.1.1"
o.rmempty     = false

o = ss:option(Value, "ser_port", "端口")
o.datatype = "port"

-- 第四块：DNS劫持
sh = m:section(TypedSection, "dnshijack", "DNS 劫持")
sh.anonymous = true
sh.addremove  = true
sh.sortable   = false
sh.template   = "cbi/tblsection"
sh.rmempty    = false

o = sh:option(Flag, "enabled", "启用")
o.rmempty  = false
o.default  = o.enabled
o.cfgvalue = function(...) return Flag.cfgvalue(...) or "1" end

o = sh:option(ListValue, "type", "协议")
o:value("none",     "无协议")
o:value("tcp://",   "TCP")
o:value("udp://",   "UDP")
o:value("tls://",   "TLS")
o:value("https://", "HTTPS")
o.default = "none"

o = sh:option(Value, "ip", "地址")
o.placeholder = "例如: 8.8.8.8, 1.1.1.1, 223.5.5.5"
o.datatype    = "or(host, string)"

o = sh:option(Value, "port", "端口")
o.datatype = "port"

-- 第五块：认证
sa = m:section(TypedSection, "authentication", "代理认证")
sa.anonymous = true
sa.addremove  = true
sa.sortable   = false
sa.template   = "cbi/tblsection"
sa.rmempty    = false

o = sa:option(Flag, "enabled", "启用")
o.rmempty  = false
o.default  = o.enabled
o.cfgvalue = function(...) return Flag.cfgvalue(...) or "1" end

o = sa:option(Value, "username", "用户名")
o.placeholder = "不能为空"

o = sa:option(Value, "password", "密码")
o.placeholder = "不能为空"

local apply = luci.http.formvalue("cbi.apply")
if apply then
	m.uci:commit("clash")
	restart_if_running()
end

return m
