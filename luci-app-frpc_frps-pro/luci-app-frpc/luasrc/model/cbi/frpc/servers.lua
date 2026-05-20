-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"

local m, s, o

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("Frps 服务器") })
m:append(Template("frpc/theme"))
m:append(Template("frpc/servers_poll"))

s = m:section(TypedSection, "server")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/services/frpc/servers/%s")
function s.create(...)
	local sid = TypedSection.create(...)
	if sid then
		-- 新建服务器默认禁用 + 给出合理默认值，避免用户跳到详情页看到空字段
		m.uci:set("frpc", sid, "enabled", "0")
		if not m.uci:get("frpc", sid, "alias") then
			m.uci:set("frpc", sid, "alias", sid)
		end
		if not m.uci:get("frpc", sid, "serverPort") then
			m.uci:set("frpc", sid, "serverPort", "7000")
		end
		if not m.uci:get("frpc", sid, "webServer__addr") then
			m.uci:set("frpc", sid, "webServer__addr", "127.0.0.1")
		end
		m.uci:save("frpc")
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(DummyValue, "_status", translate("状态 / 操作"))
o.template = "frpc/server_row"
o.rawhtml = true
o.cfgvalue = function() return "" end

o = s:option(DummyValue, "alias", translate("别名"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or translate("无")
end

o = s:option(DummyValue, "serverAddr", translate("服务端地址"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "0.0.0.0"
end

o = s:option(DummyValue, "serverPort", translate("服务端端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "7000"
end

o = s:option(DummyValue, "transport__tcpMux", translate("TCP Mux"))
o.cfgvalue = function (...)
	local v = Value.cfgvalue(...)
	return v == "false" and translate("关闭") or translate("开启")
end

o = s:option(Button, "_copy", translate("复制"))
o.inputtitle = translate("复制")
o.inputstyle = "apply"
o.write = function(self, section)
	luci.http.redirect(dsp.build_url("admin/services/frpc/server_copy/" .. section))
end

return m
