-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com> #modify by superzjg@gmail.com 20240811
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"
local uci = require("luci.model.uci").cursor()

local m, s, o

local sid = arg[1]

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("编辑代理规则") })
m.redirect = dsp.build_url("admin/services/frpc/rules")
m:append(Template("frpc/theme"))

if m.uci:get("frpc", sid) ~= "rule" then
	luci.http.redirect(m.redirect)
	return
end

s = m:section(NamedSection, sid, "rule")
s.anonymous = true
s.addremove = false

-- 多实例：rule 必须归属一个 server
local server_choices = {}
local server_choice_set = {}
uci:foreach("frpc", "server", function(srv)
	local name = srv[".name"]
	server_choices[#server_choices + 1] = { name, srv.alias or name }
	server_choice_set[name] = true
end)

-- 兜底：若当前 rule.server_id 指向已不存在的 server（如老 cfgXXXXXX 漂移残留），
-- 也加进选项里以「⚠ 未知服务器」标注，避免下拉静默落到第一项掩盖问题。
local cur_sid = uci:get("frpc", sid, "server_id")
if cur_sid and cur_sid ~= "" and not server_choice_set[cur_sid] then
	server_choices[#server_choices + 1] = { cur_sid, "⚠ 未知服务器: " .. cur_sid }
end

o = s:option(ListValue, "server_id", translate("归属服务器"))
o.rmempty = false
for _, c in ipairs(server_choices) do
	o:value(c[1], c[2])
end
o.description = translate("此规则仅会写入该服务器对应的 frpc 实例")

o = s:option(Flag, "enabled", translate("启用"))

o = s:option(Value, "name", translate("代理名称 (name)"), translate("规则的名称不要重复"))
o:value("ssh")
o:value("web")
o:value("dns")
o:value("plugin_")
o:value("secret_")
o:value("p2p_")
o.rmempty = false

o = s:option(Value, "type", translate("类型 (type)"))
o:value("tcp")
o:value("udp")
o:value("http")
o:value("https")
o:value("stcp")
o:value("xtcp")
o:value("sudp")
o:value("tcpmux")

o = s:option(Value, "PlUgIn_type", translate("插件类型 (plugin.type)"), translate("插件类型要与代理类型相匹配，请参阅官方文档"))
o:value("", translate("（空）"))
o:value("unix_domain_socket")
o:value("http_proxy")
o:value("socks5")
o:value("static_file")
o:value("https2http")
o:value("https2https")
o:value("http2https")
o:value("http2http")
o:value("tls2raw")

o = s:option(Value, "unixPath", "%s - %s (plugin.unixPath)" % { translate("插件"), translate("Unix域套接字地址") })
o.datatype = "file"
o:depends("PlUgIn_type", "unix_domain_socket")

o = s:option(Value, "username", "%s - %s (plugin.username)" % { translate("插件"), translate("用户") })
o:depends("PlUgIn_type", "socks5")

o = s:option(Value, "password", "%s - %s (plugin.password)" % { translate("插件"), translate("密码") })
o:depends("PlUgIn_type", "socks5")

o = s:option(Value, "localPath", "%s - %s (plugin.localPath)" % { translate("插件"), translate("本地路径") })
o:depends("PlUgIn_type", "static_file")

o = s:option(Value, "stripPrefix", "%s - %s (plugin.stripPrefix)" % { translate("插件"), translate("去除前缀") })
o:depends("PlUgIn_type", "static_file")

o = s:option(Value, "PlUgIn_httpUser", "%s - %s (plugin.httpUser)" % { translate("插件"), translate("HTTP 用户") })
o:depends("PlUgIn_type", "http_proxy")
o:depends("PlUgIn_type", "static_file")

o = s:option(Value, "PlUgIn_httpPassword", "%s - %s (plugin.httpPassword)" % { translate("插件"), translate("HTTP 密码") })
o:depends("PlUgIn_type", "http_proxy")
o:depends("PlUgIn_type", "static_file")

o = s:option(Value, "localAddr", "%s - %s (plugin.localAddr)" % { translate("插件"), translate("本地地址") })
o:depends("PlUgIn_type", "https2http")
o:depends("PlUgIn_type", "https2https")
o:depends("PlUgIn_type", "http2https")
o:depends("PlUgIn_type", "http2http")
o:depends("PlUgIn_type", "tls2raw")

o = s:option(Value, "crtPath", "%s - %s (plugin.crtPath)" % { translate("插件"), translate("证书路径") })
o.datatype = "file"
o:depends("PlUgIn_type", "https2http")
o:depends("PlUgIn_type", "https2https")
o:depends("PlUgIn_type", "tls2raw")

o = s:option(Value, "keyPath", "%s - %s (plugin.keyPath)" % { translate("插件"), translate("私钥路径") })
o.datatype = "file"
o:depends("PlUgIn_type", "https2http")
o:depends("PlUgIn_type", "https2https")
o:depends("PlUgIn_type", "tls2raw")

o = s:option(Value, "PlUgIn_hostHeaderRewrite", "%s - %s (plugin.hostHeaderRewrite)" % { translate("插件"), translate("主机头重写") })
o:depends("PlUgIn_type", "https2http")
o:depends("PlUgIn_type", "https2https")
o:depends("PlUgIn_type", "http2https")
o:depends("PlUgIn_type", "http2http")

o = s:option(Value, "secretKey", translate("安全密钥sk (secretKey)"))
o:depends("type", "stcp")
o:depends("type", "xtcp")
o:depends("type", "sudp")

o = s:option(Value, "multiplexer", translate("复用器类型 (multiplexer)"))
o:value("httpconnect")
o:depends("type", "tcpmux")

o = s:option(Flag, "visitor", translate("作为访客 (visitor)"))
o:depends("type", "stcp")
o:depends("type", "xtcp")
o:depends("type", "sudp")

o = s:option(Value, "localIP", translate("本地 IP (localIP)"))
o.datatype = "host"
o:depends({visitor="", PlUgIn_type=""})

o = s:option(Value, "localPort", translate("本地端口 (localPort)"))
o:depends({visitor="", PlUgIn_type=""})

o = s:option(Value, "remotePort", translate("远程端口 (remotePort)"))
o:depends("type", "tcp")
o:depends("type", "udp")

o = s:option(Value, "serverName", translate("服务端名称 (serverName)"), translate("要连接的对端代理「规则名」（不是机器名）。即被访问端那条 stcp/xtcp/sudp 规则的「代理名称 name」。配合下方 serverUser（哪台机器）共同定位目标"))
o:depends("visitor", "1")

o = s:option(Value, "serverUser", translate("服务端用户 (serverUser)"), translate("对端代理所在那台机器/节点的客户端身份（即被访问端 frpc 的「用户名 user」，也就是 Client / Node 节点名）。要和对端 frpc 实例「常规配置→用户名(User)」填的一字不差（注意空格 ≠ 连字符）。若留空则默认为当前实例自己的用户"))
o:depends("visitor", "1")

o = s:option(Value, "bindAddr", translate("绑定地址 (bindAddr)"))
o.datatype = "host"
o:depends("visitor", "1")

o = s:option(Value, "bindPort", translate("绑定端口 (bindPort)"))
o:depends("visitor", "1")
o.datatype = "integer"

o = s:option(Value, "allowUsers", translate("允许的访客用户 (allowUsers)"), translate("若留空，默认只允许同一用户下的 visitor 访问；若指定具体用户，用英文逗号隔开，例如简写为：user1, user2 即可，后台会转换格式"))
o:value("", translate("（空）"))
o:value("*", translate("所有用户"))
o:depends({visitor="", type="xtcp"})
o:depends({visitor="", type="stcp"})
o:depends({visitor="", type="sudp"})

o = s:option(Flag, "keepTunnelOpen", translate("保持隧道打开 (keepTunnelOpen)"), translate("定期检查隧道状态并尝试保持打开。默认关闭"))
o.enabled = "true"
o.disabled = ""
o:depends({visitor="1", type="xtcp"})

o = s:option(Value, "maxRetriesAnHour", translate("每小时尝试次数 (maxRetriesAnHour)"))
o:depends("keepTunnelOpen", "true")
o.placeholder = "8"
o.datatype = "integer"

o = s:option(Value, "minRetryInterval", translate("最小重试间隔秒数 (minRetryInterval)"))
o:depends("keepTunnelOpen", "true")
o.placeholder = "90"
o.datatype = "integer"

o = s:option(Value, "httpUser", translate("HTTP 用户 (httpUser)"))
o:depends("type", "http")
o:depends("type", "tcpmux")

o = s:option(Value, "httpPassword", translate("HTTP 密码 (httpPassword)"))
o:depends("type", "http")
o:depends("type", "tcpmux")

o = s:option(Value, "subdomain", translate("子域名 (subdomain)"))
o:depends("type", "http")
o:depends("type", "https")
o:depends("type", "tcpmux")

o = s:option(Value, "customDomains", translate("自定义域名列表 (customDomains)"))
o:depends("type", "http")
o:depends("type", "https")
o:depends("type", "tcpmux")

o = s:option(Value, "locations", translate("location 配置 (locations)"), translate("指定具体路径，用英文逗号隔开，例如简写为：/, /pic 即可，后台会转换格式"))
o:depends("type", "http")

o = s:option(Value, "hostHeaderRewrite", translate("主机头重写 (hostHeaderRewrite)"))
o:depends("type", "http")
o:depends("type", "https")

o = s:option(Value, "transport__bandwidthLimit", translate("带宽限流大小 (transport.bandwidthLimit)"), translate("单位为 MB 或 KB，例如：3MB"))
o = s:option(ListValue, "transport__bandwidthLimitMode", translate("带宽限流类型 (transport.bandwidthLimitMode)"), translate("留空默认：client"))
o:value("", translate("（空）"))
o:value("server")
o:value("client")

o = s:option(Flag, "transport__useEncryption", translate("使用加密 (transport.useEncryption)"), translate("更安全，但消耗更多系统资源，默认关闭。注意：frp全局默认启用TLS加密，若未禁用，除xtcp外，此处不应开启（重复加密）"))
o.enabled = "true"
o.disabled = ""
o.default = o.disabled

o = s:option(Flag, "transport__useCompression", translate("使用压缩 (transport.useCompression)"), translate("降低数据流量，但消耗更多系统资源，默认关闭"))
o.enabled = "true"
o.disabled = ""
o.default = o.disabled

o = s:option(ListValue, "transport__proxyProtocolVersion", translate("代理协议版本 (transport.proxyProtocolVersion)"))
o:value("", translate("（无）"))
o:value("v1")
o:value("v2")
o:depends("type", "tcp")
o:depends("type", "http")
o:depends("type", "https")
o:depends({type="stcp", visitor=""})
o:depends({type="xtcp", visitor=""})
o:depends("type", "tcpmux")

o = s:option(Value, "loadBalancer__group", translate("负载均衡分组名 (loadBalancer.group)"))
o:depends("type", "tcp")
o:depends("type", "http")
o:depends("type", "tcpmux")

o = s:option(Value, "loadBalancer__groupKey", translate("负载均衡分组密钥 (loadBalancer.groupKey)"))
o:depends("type", "tcp")
o:depends("type", "http")
o:depends("type", "tcpmux")

o = s:option(ListValue, "healthCheck__type", "%s - %s (healthCheck.type)" % { translate("健康检查"), translate("类型") })
o:value("", translate("（空）"))
o:value("tcp", "TCP")
o:value("http", "HTTP")
o:depends("type", "tcp")
o:depends("type", "http")

o = s:option(Value, "healthCheck__path", "%s - %s (healthCheck.path)" % { translate("健康检查"), translate("http接口路径") })
o:depends("healthCheck__type", "http")

o = s:option(Value, "healthCheck__timeoutSeconds", "%s - %s (healthCheck.timeoutSeconds)" % { translate("健康检查"), translate("超时秒数") })
o.datatype = "uinteger"
o.placeholder = "3"
o:depends("healthCheck__type", "tcp")
o:depends("healthCheck__type", "http")

o = s:option(Value, "healthCheck__maxFailed", "%s - %s (healthCheck.maxFailed)" % { translate("健康检查"), translate("最大失败次数") })
o.datatype = "uinteger"
o.placeholder = "3"
o:depends("healthCheck__type", "tcp")
o:depends("healthCheck__type", "http")

o = s:option(Value, "healthCheck__intervalSeconds", "%s - %s (healthCheck.intervalSeconds)" % { translate("健康检查"), translate("间隔秒数") })
o.datatype = "uinteger"
o.placeholder = "10"
o:depends("healthCheck__type", "tcp")
o:depends("healthCheck__type", "http")

o = s:option(DynamicList, "extra_options", translate("额外选项 1"),
	translate("点击添加列表1，写入 [[proxies]] 或 [[visitors]] 末尾，一行一条，格式错误可能无法启动服务"))
o.placeholder = "option = value"
o = s:option(DynamicList, "extra_options_plugin", translate("额外选项 2"),
	translate("点击添加列表2，写入插件功能 [proxies.plugin] 末尾..."))
o.placeholder = "option = value"

return m
