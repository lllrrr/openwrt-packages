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

-- 用稳定命名创建 server，避免 UCI 匿名 cfgXXXXXX 因 section 位置变化而漂移，
-- 导致 rule.server_id 引用悬空（v3 修复，详见 uci-defaults/40_luci-frpc migrate_v3）。
function s.create(...)
	local stable_sid = string.format("srv_%d_%d", os.time(), math.random(1000, 9999))
	-- 极端兜底：万一同秒同随机数已存在，自旋几次
	for _ = 1, 5 do
		if not m.uci:get("frpc", stable_sid) then break end
		stable_sid = string.format("srv_%d_%d", os.time(), math.random(1000, 9999))
	end
	m.uci:set("frpc", stable_sid, "server")
	-- 默认禁用 + 合理默认值，避免用户跳到详情页看到空字段
	m.uci:set("frpc", stable_sid, "enabled", "0")
	m.uci:set("frpc", stable_sid, "alias", stable_sid)
	m.uci:set("frpc", stable_sid, "serverPort", "7000")
	m.uci:set("frpc", stable_sid, "webServer__addr", "127.0.0.1")
	m.uci:save("frpc")
	luci.http.redirect(s.extedit % stable_sid)
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
