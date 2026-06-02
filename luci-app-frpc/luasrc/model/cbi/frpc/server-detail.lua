-- 多实例：server section 编辑页（接收从 main 下沉的所有 frps 连接字段）
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"

local m, s, o

local sid = arg[1]
if not sid or uci:get("frpc", sid) ~= "server" then
	luci.http.redirect(luci.dispatcher.build_url("admin/services/frpc/servers"))
	return
end

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("服务器配置") },
	translate("配置好 frps 地址 / 端口 / 认证 token 后，勾选「启用此实例」并保存即可启动该 frpc 实例。Admin 端口留空将自动分配（7400 起）。"))
m:append(Template("frpc/theme"))

s = m:section(NamedSection, sid, "server")
s.addremove = false
s.anonymous = true

s:tab("general", translate("常规"))
s:tab("advanced", translate("高级"))
s:tab("manage", translate("管理"))
s:tab("log", translate("日志"))

-- === general ===
o = s:taboption("general", Flag, "enabled", translate("启用此实例"))
o.default = "0"

o = s:taboption("general", Value, "alias", translate("别名"))
o.placeholder = sid

o = s:taboption("general", Value, "client_file", translate("可执行文件（留空 = 全局默认）"))
o.datatype = "file"

o = s:taboption("general", ListValue, "run_user", translate("运行用户（留空 = 全局默认）"))
o:value("", translate("-- 全局默认 --"))
for user in util.execi("cat /etc/passwd | cut -d':' -f1") do
	if user then o:value(user) end
end

o = s:taboption("general", Value, "serverAddr", translate("frps 地址"))
o.rmempty = false

o = s:taboption("general", Value, "serverPort", translate("frps 端口"))
o.datatype = "port"
o.default = "7000"

o = s:taboption("general", Value, "user", translate("用户名"))

o = s:taboption("general", ListValue, "auth__method", translate("认证方式"))
o:value("", translate("无"))
o:value("token", "token")
o:value("oidc", "oidc")

o = s:taboption("general", Value, "auth__token", translate("Token"))
o:depends("auth__method", "token")

-- === advanced ===
o = s:taboption("advanced", ListValue, "transport__protocol", translate("传输协议"))
o:value("", translate("默认 tcp"))
o:value("tcp"); o:value("kcp"); o:value("quic"); o:value("websocket"); o:value("wss")

o = s:taboption("advanced", Flag, "transport__tcpMux", translate("启用 tcpMux"))
o.enabled = "true"
o.disabled = "false"

o = s:taboption("advanced", Value, "transport__poolCount", translate("连接池数量 poolCount"))
o.datatype = "uinteger"
o.description = translate("预先与 frps 建立的连接数。瞬断时活动代理不易掉线，链路不稳时建议设 1~5。")

o = s:taboption("advanced", Value, "transport__heartbeatInterval", translate("心跳间隔（秒）"))
o.datatype = "integer"

o = s:taboption("advanced", Value, "transport__heartbeatTimeout", translate("心跳超时（秒）"))
o.datatype = "integer"

o = s:taboption("advanced", Flag, "transport__tls__enable", translate("启用 TLS"))
o.enabled = "true"
o.disabled = "false"

o = s:taboption("advanced", Value, "transport__tls__serverName", translate("TLS serverName"))
o:depends("transport__tls__enable", "true")

o = s:taboption("advanced", Flag, "transport__tls__disableCustomTLSFirstByte", translate("禁用 TLS 伪装首字节（DPI 绕过）"))
o.enabled = "true"
o.disabled = "false"
o:depends("transport__tls__enable", "true")
o.description = translate("frp 默认在 TLS 前发一个 0x17 伪装字节，部分网络的 DPI 会因此掐断连接（EOF）。开启此项可关闭该伪装字节用于排查/绕过。frps 端需一致。")

o = s:taboption("advanced", Value, "dnsServer", translate("DNS 服务器"))
o.datatype = "host"

o = s:taboption("advanced", Value, "natHoleStunServer", translate("NAT 打洞 STUN 服务器"))

o = s:taboption("advanced", Flag, "loginFailExit", translate("登录失败退出"))
o.enabled = "true"
o.disabled = "false"

-- === manage（每实例独立 admin webServer）===
o = s:taboption("manage", Flag, "admin_enabled", translate("启用 Admin Dashboard"))
o.default = "0"
o.description = translate("启用后 frpc 会监听一个 HTTP 端口，可查看 proxy 状态、流量统计。多数场景无需开启。")

o = s:taboption("manage", Value, "admin_port", translate("Admin 端口（留空 = 自动分配 7400 起）"))
o.datatype = "port"
o:depends("admin_enabled", "1")

o = s:taboption("manage", Value, "webServer__addr", translate("Admin 监听地址"))
o.default = "127.0.0.1"
o.description = translate("默认 127.0.0.1 仅本机；改为 0.0.0.0 可从 LAN 访问 Dashboard")
o:depends("admin_enabled", "1")

o = s:taboption("manage", Value, "admin_user", translate("Admin 用户"))
o:depends("admin_enabled", "1")

o = s:taboption("manage", Value, "admin_password", translate("Admin 密码"))
o:depends("admin_enabled", "1")

-- === log ===
o = s:taboption("log", Flag, "enable_logging", translate("启用日志"))

o = s:taboption("log", Value, "log__to", translate("日志路径"))
o:depends("enable_logging", "1")
o.description = translate("留空默认 /var/log/frpc/<server>.log")

o = s:taboption("log", ListValue, "log__level", translate("日志级别"))
o:depends("enable_logging", "1")
o:value("trace"); o:value("debug"); o:value("info"); o:value("warn"); o:value("error")

o = s:taboption("log", Value, "log__maxDays", translate("最大保留天数"))
o:depends("enable_logging", "1")
o.datatype = "uinteger"

o = s:taboption("log", Flag, "std_redirect", translate("捕获 stdout/stderr 到日志"))
o:depends("enable_logging", "1")

return m
