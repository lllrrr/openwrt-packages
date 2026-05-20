-- Multi-instance frps: instance list view
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"

local m, s, o

m = Map("frps", "%s - %s" % { translate("Frps"), translate("FRPS 实例") })
m:append(Template("frps/theme"))
m:append(Template("frps/instances_poll"))

s = m:section(TypedSection, "instance")
s.anonymous = true
s.addremove = true
s.sortable = false
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/services/frps/instances/%s")

function s.create(...)
	local sid = TypedSection.create(...)
	if sid then
		-- 新建实例默认禁用 + 合理默认值
		m.uci:set("frps", sid, "enabled", "0")
		if not m.uci:get("frps", sid, "alias") then
			m.uci:set("frps", sid, "alias", sid)
		end
		if not m.uci:get("frps", sid, "bindPort") then
			m.uci:set("frps", sid, "bindPort", "7000")
		end
		m.uci:save("frps")
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(DummyValue, "_status", translate("状态 / 操作"))
o.template = "frps/instance_row"
o.rawhtml = true
o.cfgvalue = function() return "" end

o = s:option(DummyValue, "alias", translate("别名"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or translate("无")
end

o = s:option(DummyValue, "bindAddr", translate("绑定地址"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "0.0.0.0"
end

o = s:option(DummyValue, "bindPort", translate("绑定端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "7000"
end

o = s:option(DummyValue, "vhostHTTPPort", translate("HTTP 端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "-"
end

o = s:option(DummyValue, "webServer__port", translate("管理面板端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "-"
end

o = s:option(Button, "_copy", translate("复制"))
o.inputtitle = translate("复制")
o.inputstyle = "apply"
o.write = function(self, section)
	luci.http.redirect(dsp.build_url("admin/services/frps/instance_copy/" .. section))
end

return m
