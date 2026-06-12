local arg = arg or {}
local sid = arg[1]
local dsp = require "luci.dispatcher"
local sys = require "luci.sys"

if not sid or sid == "" then
	luci.http.redirect(dsp.build_url("admin/vpn/singbox-server"))
	return
end

m = Map("singbox_server", translate("服务器配置"))
m.redirect = dsp.build_url("admin/vpn/singbox-server")

s = m:section(NamedSection, sid, "server")
s.anonymous = true
s.addremove = false

function m.on_after_commit(self)
	local uci = require "luci.model.uci".cursor()
	local enabled = uci:get("singbox_server", sid, "enabled") or "0"

	-- 只有当前节点启用时才触发 sing-box reload；未启用则只保存配置，不重载服务
	if enabled == "1" then
		sys.call("/etc/init.d/singbox_server reload >/dev/null 2>&1 &")
	end

	-- 保存应用后统一跳转回概览页
	luci.http.redirect(dsp.build_url("admin/vpn/singbox-server"))
end

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:option(Value, "remarks", translate("备注"))
o.default = translate("备注")
o.rmempty = true

o = s:option(Flag, "custom_config", translate("使用自定义配置"))
o.rmempty = false

o = s:option(TextValue, "custom_json", translate("自定义配置内容"))
o.rows = 18
o.wrap = "off"
o:depends("custom_config", "1")

o = s:option(ListValue, "protocol", translate("协议"))
o:value("vmess", "Vmess")
o:value("vless", "VLESS")
o:value("trojan", "Trojan")
o:value("hysteria2", "Hysteria2")
o:value("tuic", "TUIC")
o.default = "vmess"

o = s:option(Value, "listen_port", translate("监听端口"))
o.datatype = "port"
o.default = "4566"
o.rmempty = false

o = s:option(Value, "uuid", translate("ID/密码"), translate("VMess/VLESS/TUIC 使用 UUID；Trojan/Hysteria2/TUIC 使用密码。留空时默认使用 ba9872bc-ebdf-4ce2-8c6f-fce7fa2357aa。"))
o.default = "ba9872bc-ebdf-4ce2-8c6f-fce7fa2357aa"
o.placeholder = "ba9872bc-ebdf-4ce2-8c6f-fce7fa2357aa"
o.rmempty = true

o = s:option(Value, "password", translate("密码"))
o.password = true
o.rmempty = true
o:depends("protocol", "trojan")
o:depends("protocol", "hysteria2")
o:depends("protocol", "tuic")

o = s:option(Flag, "tls", "TLS")
o.rmempty = false

o = s:option(Value, "server_name", translate("TLS/Reality Server Name"))
o.placeholder = "example.com"
o:depends("tls", "1")
o:depends("reality", "1")

o = s:option(Value, "cert_path", translate("证书路径"))
o.placeholder = "/etc/singbox/server.crt"
o:depends("tls", "1")

o = s:option(Value, "key_path", translate("私钥路径"))
o.placeholder = "/etc/singbox/server.key"
o:depends("tls", "1")

o = s:option(Flag, "reality", "Reality")
o.rmempty = false
o:depends("protocol", "vless")

o = s:option(Value, "reality_private_key", translate("Reality 私钥"), translate("可使用 sing-box generate reality-keypair 生成。"))
o:depends("reality", "1")

o = s:option(Value, "reality_short_id", translate("Reality Short ID"))
o.placeholder = "0123456789abcdef"
o:depends("reality", "1")

o = s:option(ListValue, "transport", translate("传输方式"))
o:value("tcp", "TCP")
o:value("ws", "WebSocket")
o:value("grpc", "gRPC")
o.default = "ws"
o:depends("protocol", "vmess")
o:depends("protocol", "vless")
o:depends("protocol", "trojan")

o = s:option(Value, "ws_host", "WebSocket Host")
o:depends("transport", "ws")

o = s:option(Value, "ws_path", "WebSocket Path")
o.default = "/"
o:depends("transport", "ws")

o = s:option(Value, "grpc_service_name", translate("gRPC Service Name"))
o.default = "grpc"
o:depends("transport", "grpc")

o = s:option(Flag, "mux", "Mux")
o.rmempty = false

o = s:option(Flag, "local_listen", translate("本机监听"), translate("当勾选时，只能本机访问。"))
o.rmempty = false

o = s:option(Flag, "lan_access", translate("接受局域网访问"), translate("当勾选时，可以直接访问局域网，这将不安全！（非特殊情况不建议开启）"))
o.rmempty = false

o = s:option(Flag, "log", translate("日志"))
o.default = "0"
o.rmempty = false

return m
